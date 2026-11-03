//! The document editor, for records and for terms: a new document of a definition, or an
//! existing one. The editor is a fragment (RecordEditor) the page wraps in its shell and
//! the drawer fetches bare; a post from the editor's script asks, by the `Publr-Fragment`
//! header, for the editor drawn again (`editor`) or for a JSON verdict (`json`, the
//! autosave) instead of a redirect. `content/form.zig` and `terms.zig` instantiate it.
const std = @import("std");
const site_dimensions = @import("../../operations/dimensions.zig");
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
    /// What is scheduled for it (`record.transition_at`), soonest first.
    scheduled: []const Scheduled = &.{},
    /// The scheduled version shown (`?version=`): its entry; 0 for the record as it is.
    version: i64 = 0,
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
    /// Over the problems, when they are not a refused save's: `Not published`.
    problems_title: []const u8 = "",
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
    /// What of a saved document goes live, in the Publishing section: a record's map of its
    /// dimensions; null for a domain with none.
    live: ?fn (
        session: *Session,
        def: Def,
        row: Record,
        document: ?Value,
    ) Error!?admin.render.Node = null,
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
            const document = fields.decode.document_of(
                session.arena,
                admin.kinds_of(session),
                form_defs,
                form,
            ) orelse {
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

            const defs = try varied(session, shape.def.fields, .{
                .type = shape.def.handle,
                .id = id,
            });
            const document = fields.decode.document_of(
                session.arena,
                admin.kinds_of(session),
                defs,
                form,
            ) orelse {
                return admin.fail(session, error.Invalid, back);
            };
            const location = try print(session.arena, "{s}/{s}", .{ back, id });
            const expected = expected_version_of(form) orelse {
                return admin.fail(session, error.Invalid, location);
            };
            const version = shape.loaded.?.version;

            if (comptime @hasDecl(operations, "SaveVersion")) {
                if (version > 0) {
                    _ = registry.SDK.dispatch(&session.ctx, operations.SaveVersion, .{
                        .id = id,
                        .version = version,
                        .document = document,
                    }) catch |err| return refused(session, shape, form, err, document);

                    return saved(session, id);
                }
            }

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

        /// A status action posted from the aside: publish, discard, or a transition (destroy
        /// among them, for a document in the trash).
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
                }) catch |err| return move_refused(session, id, err, location);
            } else if (std.mem.eql(u8, verb, "decline")) {
                if (comptime !@hasDecl(operations, "DeclineRequest")) {
                    return admin.fail(session, error.Invalid, location);
                } else {
                    _ = registry.SDK.dispatch(&session.ctx, operations.DeclineRequest, .{
                        .id = id,
                    }) catch |err| return admin.fail(session, err, location);
                }
            } else if (std.mem.eql(u8, verb, "schedule")) {
                return schedule(session, form, id, location);
            } else if (on_scheduled(verb)) {
                if (comptime !@hasDecl(operations, "PublishVersion")) {
                    return admin.fail(session, error.Invalid, location);
                } else {
                    return scheduled_action(session, form, id, verb);
                }
            } else if (std.mem.eql(u8, verb, "live")) {
                if (comptime !@hasDecl(operations, "HoldBack")) {
                    return admin.fail(session, error.Invalid, location);
                } else {
                    _ = registry.SDK.dispatch(&session.ctx, operations.HoldBack, .{
                        .id = id,
                        .combinations = try held_back_of(session.arena, form),
                    }) catch |err| return move_refused(session, id, err, location);
                }
            } else if (std.mem.eql(u8, verb, "discard")) {
                _ = registry.SDK.dispatch(&session.ctx, operations.DiscardChanges, .{
                    .id = id,
                    .expected_version = expected,
                }) catch |err| return admin.fail(session, err, location);
            } else {
                const transition = form.text("transition") orelse {
                    return admin.fail(session, error.Invalid, location);
                };
                const moved = registry.SDK.dispatch(&session.ctx, operations.Transition, .{
                    .id = id,
                    .transition = transition,
                    .expected_version = expected,
                }) catch |err| return move_refused(session, id, err, location);

                if (std.mem.eql(u8, moved.status, "destroyed")) {
                    if (fragment) {
                        return answer_gone(session, back);
                    }

                    return response.redirect(.see_other, back);
                }
            }

            if (fragment) {
                return answer_loaded(session, id);
            }

            try response.redirect(.see_other, location);
        }

        /// The combinations offered (`offered`) but not ticked (`live`): what the record
        /// holds back.
        fn held_back_of(
            arena: std.mem.Allocator,
            form: *const admin.Form,
        ) Error![]const []const u8 {
            std.debug.assert(form.len <= admin.form_pairs_max);

            var held: std.ArrayList([]const u8) = .empty;

            for (form.pairs[0..form.len]) |offered| {
                if (!std.mem.eql(u8, offered.name, "offered")) {
                    continue;
                }

                const ticked = for (form.pairs[0..form.len]) |live| {
                    const is_live = std.mem.eql(u8, live.name, "live");

                    if (is_live and std.mem.eql(u8, live.value, offered.value)) {
                        break true;
                    }
                } else false;

                if (!ticked) {
                    held.append(arena, offered.value) catch return error.OutOfMemory;
                }
            }

            return held.items;
        }

        /// Schedules the form's `transition` at its `at`, typed on the site's clock; a version
        /// scheduled opens, to edit as the record will read then.
        fn schedule(
            session: *Session,
            form: *const Form,
            id: []const u8,
            location: []const u8,
        ) Error!void {
            std.debug.assert(id.len > 0);
            std.debug.assert(location.len > 0);

            if (comptime !@hasDecl(operations, "TransitionAt")) {
                return admin.fail(session, error.Invalid, location);
            } else {
                const local = model_time.parse_datetime_local(form.text("at") orelse "") orelse {
                    return admin.fail(session, error.Invalid, location);
                };
                const transition = form.text("transition") orelse "";
                const base = std.fmt.parseInt(i64, form.text("base") orelse "", 10) catch 0;
                const made = registry.SDK.dispatch(&session.ctx, operations.TransitionAt, .{
                    .id = id,
                    .transition = transition,
                    .at = zone.utc_of((try site_zone(session)).rule, local),
                    .base = base,
                }) catch |err| return move_refused(session, id, err, location);
                const opens = std.mem.eql(u8, transition, "publish") and made.entry > 0;
                const next = if (opens) try page_of(session, id, made.entry) else location;

                if (wants_fragment(session)) {
                    if (opens) {
                        return answer_gone(session, next);
                    }

                    return answer_loaded(session, id);
                }

                return session.response.redirect(.see_other, next);
            }
        }

        /// What the scheduled entry shown, or the one the form names, does now: `publish_version`
        /// (it, and every one before, live now), `run` (the next one, now), `move` (to `at`),
        /// `unschedule`. Done with it, the editor shows the record as it is.
        fn scheduled_action(
            session: *Session,
            form: *const Form,
            id: []const u8,
            verb: []const u8,
        ) Error!void {
            std.debug.assert(id.len > 0);
            std.debug.assert(verb.len > 0);

            const named = std.fmt.parseInt(i64, form.text("entry") orelse "", 10) catch 0;
            const entry = if (named > 0) named else version_of(session);
            const shown = try page_of(session, id, version_of(session));
            const live_page = try page_of(session, id, 0);
            const SDK = registry.SDK;
            var stays = false;

            if (std.mem.eql(u8, verb, "publish_version")) {
                _ = SDK.dispatch(&session.ctx, operations.PublishVersion, .{
                    .id = id,
                    .version = entry,
                }) catch |err| return move_refused(session, id, err, shown);
            } else if (std.mem.eql(u8, verb, "save_into")) {
                _ = SDK.dispatch(&session.ctx, operations.SaveIntoScheduled, .{
                    .id = id,
                    .version = entry,
                }) catch |err| return move_refused(session, id, err, shown);
                stays = true;
            } else if (std.mem.eql(u8, verb, "discard_draft")) {
                const draft = try draft_id(session, id, entry) orelse {
                    return admin.fail(session, error.NotFound, shown);
                };

                _ = SDK.dispatch(&session.ctx, operations.Unschedule, .{
                    .id = id,
                    .entry = draft,
                }) catch |err| return admin.fail(session, err, shown);
                stays = true;
            } else if (std.mem.eql(u8, verb, "run")) {
                _ = SDK.dispatch(&session.ctx, operations.RunScheduled, .{
                    .id = id,
                    .entry = entry,
                }) catch |err| return move_refused(session, id, err, shown);
            } else if (std.mem.eql(u8, verb, "move")) {
                const local = model_time.parse_datetime_local(form.text("at") orelse "") orelse {
                    return admin.fail(session, error.Invalid, shown);
                };

                _ = SDK.dispatch(&session.ctx, operations.Reschedule, .{
                    .id = id,
                    .entry = entry,
                    .at = zone.utc_of((try site_zone(session)).rule, local),
                }) catch |err| return admin.fail(session, err, shown);
                stays = true;
            } else {
                _ = SDK.dispatch(&session.ctx, operations.Unschedule, .{
                    .id = id,
                    .entry = entry,
                }) catch |err| return admin.fail(session, err, shown);
            }

            const location = if (stays) shown else live_page;

            if (wants_fragment(session)) {
                return answer_gone(session, location);
            }

            return session.response.redirect(.see_other, location);
        }

        /// The draft kept on top of scheduled change `version`; null when none is.
        fn draft_id(session: *Session, id: []const u8, version: i64) Error!?i64 {
            std.debug.assert(id.len > 0);
            std.debug.assert(version > 0);

            const got = registry.SDK.dispatch(&session.ctx, operations.Get, .{
                .id = id,
                .purpose = .edit,
            }) catch return null;

            for (got.scheduled) |one| {
                if (std.mem.eql(u8, one.state, "draft") and one.base == version) {
                    return one.entry;
                }
            }

            return null;
        }

        /// Whether `verb` acts on a scheduled entry.
        fn on_scheduled(verb: []const u8) bool {
            std.debug.assert(verb.len <= 64);

            const verbs = [_][]const u8{
                "publish_version",
                "run",
                "move",
                "unschedule",
                "save_into",
                "discard_draft",
            };

            for (verbs) |known| {
                if (std.mem.eql(u8, verb, known)) {
                    return true;
                }
            }

            return false;
        }

        /// The editor's page of `id`, showing its scheduled version `version` (0: as it is).
        fn page_of(session: *Session, id: []const u8, version: i64) Error![]const u8 {
            std.debug.assert(id.len > 0);
            std.debug.assert(version >= 0);

            if (version == 0) {
                return print(session.arena, "{s}/{s}", .{ back, id });
            }

            return print(session.arena, "{s}/{s}?version={d}", .{ back, id, version });
        }

        /// A publish or transition refused: the editor again with each problem under its
        /// field when the refusal names fields (a value a language requires), else the
        /// message page.
        fn move_refused(
            session: *Session,
            id: []const u8,
            err: anyerror,
            location: []const u8,
        ) Error!void {
            std.debug.assert(id.len > 0);
            std.debug.assert(location.len > 0);

            const told = session.ctx.problems;

            if (err != error.Invalid or told.len == 0) {
                return admin.fail(session, err, location);
            }

            const shape = try load(session, id) orelse return;
            const document = parse(session.arena, shape.loaded.?.document) orelse {
                return admin.fail(session, error.Invalid, location);
            };
            const problems = try session.arena.alloc(Problem, told.len);
            // An item or group past the fold holding a problem is drawn open, so it shows.
            const open = try session.arena.alloc([]const u8, told.len);
            var opened = shape;

            // Each under its field's label: a value a dimension requires is named by the
            // field it belongs to (`Body`), the message saying which value (`Polski`).
            for (told, problems, open) |one, *problem, *code| {
                const name = model.dimension.split(one.field).name;
                const label = for (shape.def.fields) |field| {
                    if (std.mem.eql(u8, field.name, name)) {
                        break field.label;
                    }
                } else one.field;

                problem.* = .{
                    .code = label,
                    .text = one.message,
                };
                code.* = one.field;
            }

            opened.open = open;
            opened.problems_title = try session.translated(
                "Not published: fill in what is marked, then publish again.",
                .{},
            );

            const how: Answer = if (wants_fragment(session)) .fragment else .page;

            try answer(session, opened, document, problems, how);
        }

        /// The definition a new document is of, from the query, or a not-found page.
        fn may_of(session: *Session, row: Record) May {
            std.debug.assert(row.id.len > 0);
            std.debug.assert(session.signed_in());

            return .{
                .destroy = registry.SDK.may(&session.ctx, operations.Purge),
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

            const version = version_of(session);
            var in: operations.Get.In = .{
                .id = id,
                .purpose = .edit,
            };

            if (@hasField(operations.Get.In, "version")) {
                in.version = version;
            }

            const full = registry.SDK.dispatch(&session.ctx, operations.Get, in) catch |err| {
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
                        &.{},
                    .version = version,
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
            const loaded = shape.loaded.?;
            // In a scheduled version, its own actions: Publish now, Remove version.
            const draft = loaded.version > 0 and draft_on(loaded.scheduled, loaded.version);
            const actions = if (loaded.version > 0) blk: {
                const listed = try without_drafts(session.arena, loaded.scheduled);
                const items = try scheduled_of(session, shape.def, row, listed);

                break :blk try version_actions(
                    session,
                    shown_of(listed, items, loaded.version),
                    draft,
                );
            } else try actions_of(session, flow, row, may_of(session, row));

            session.response.json(.ok, .{
                .saved = true,
                .id = row.id,
                .version = row.version,
                .title = row.title,
                .status = row.status,
                .status_label = try status_label_of(session, status, row.status),
                .changed = if (loaded.version > 0) draft else row.changed,
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
            const location = try page_of(session, id, shape.loaded.?.version);

            session.response.set_header("Publr-Location", location) catch return error.OutOfMemory;

            try answer(session, shape, document, &.{}, .fragment);
        }

        /// A document that is gone (destroyed): nothing to draw, the script goes to `location`.
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
            const defs = try varied(session, shape.def.fields, .{
                .type = shape.def.handle,
                .id = if (shape.loaded) |full| full.row.id else "",
            });
            const posted = fields.decode.value_of(
                session.arena,
                admin.kinds_of(session),
                defs,
                form,
            ) catch {
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

        /// The markers beside each field's label (`record.markers`) and the fields' help
        /// (`record.help`) for the form as it stands, saved or not, as JSON for the editor to
        /// draw: asked again as its values change.
        pub fn markers(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .post);
            std.debug.assert(ctx.user_data != null);

            var post = try admin.accept(request, response, ctx, back) orelse return;
            var session = &post.session;
            const form = &post.form;
            const handle = form.text("type") orelse return admin.fail(session, error.Invalid, back);
            const def = try definition_of(session, handle) orelse return;
            const defs = try varied(session, def.fields, .{});
            const document = fields.decode.document_of(
                session.arena,
                admin.kinds_of(session),
                defs,
                form,
            ) orelse {
                return admin.fail(session, error.Invalid, back);
            };

            if (comptime !@hasDecl(operations, "Markers")) {
                return session.response.json(.ok, .{
                    .markers = &[_]u8{},
                    .helps = &[_]u8{},
                }) catch error.OutOfMemory;
            } else {
                const found = registry.SDK.dispatch(&session.ctx, operations.Markers, .{
                    .type = handle,
                    .document = document,
                    .id = form.text("id") orelse "",
                }) catch |err| return admin.fail(session, err, back);
                const helped = registry.SDK.dispatch(&session.ctx, operations.Helps, .{
                    .type = handle,
                    .document = document,
                }) catch |err| return admin.fail(session, err, back);

                const version = std.fmt.parseInt(i64, form.text("version") orelse "", 10) catch 0;
                const id = form.text("id") orelse "";
                const changed = try changed_of_form(session, def, id, version, document);
                const all = try std.mem.concat(session.arena, Marker, &.{ found.markers, changed });

                return session.response.json(.ok, .{
                    .markers = all,
                    .helps = helped.helps,
                }) catch error.OutOfMemory;
            }
        }

        /// The markers beside the fields' labels for `document` as it is drawn, so the editor
        /// has them from its first frame and keeps them through a redraw. None when they
        /// cannot be worked out: the editor asks for them again.
        fn markers_drawn(
            session: *Session,
            handle: []const u8,
            document: ?Value,
            id: []const u8,
        ) Error![]const views.RecordEditor.MarkersItem {
            std.debug.assert(handle.len > 0);
            std.debug.assert(session.signed_in());

            if (comptime !@hasDecl(operations, "Markers")) {
                return &.{};
            } else {
                const value = document orelse return &.{};
                const text = std.json.Stringify.valueAlloc(session.arena, value, .{}) catch {
                    return error.OutOfMemory;
                };
                const found = registry.SDK.dispatch(&session.ctx, operations.Markers, .{
                    .type = handle,
                    .document = text,
                    .id = id,
                }) catch return &.{};
                const items = try session.arena.alloc(
                    views.RecordEditor.MarkersItem,
                    found.markers.len,
                );

                for (found.markers, items) |marker, *item| {
                    item.* = .{
                        .field = marker.field,
                        .label = marker.label,
                        .group = marker.group,
                        .tone = marker.tone,
                        .dimension = marker.dimension,
                        .code = marker.code,
                        .current = marker.current,
                        .href = marker.href,
                    };
                }

                return items;
            }
        }

        /// The fields' help as plugins give it for `document` as it is drawn (`record.help`).
        /// None when it cannot be worked out: the type's help shows until the editor asks.
        fn helps_drawn(
            session: *Session,
            handle: []const u8,
            document: ?Value,
        ) Error![]const views.RecordEditor.HelpsItem {
            std.debug.assert(handle.len > 0);
            std.debug.assert(session.signed_in());

            if (comptime !@hasDecl(operations, "Helps")) {
                return &.{};
            } else {
                const value = document orelse return &.{};
                const text = std.json.Stringify.valueAlloc(session.arena, value, .{}) catch {
                    return error.OutOfMemory;
                };
                const found = registry.SDK.dispatch(&session.ctx, operations.Helps, .{
                    .type = handle,
                    .document = text,
                }) catch return &.{};
                const items = try session.arena.alloc(
                    views.RecordEditor.HelpsItem,
                    found.helps.len,
                );

                for (found.helps, items) |one, *item| {
                    item.* = .{
                        .field = one.field,
                        .help = one.help,
                    };
                }

                return items;
            }
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
            const id = if (shape.loaded) |full| full.row.id else "";
            const form_defs = try varied(session, def.fields, .{
                .document = document,
                .type = def.handle,
                .id = id,
            });
            const rows = try with_panels(session, def.handle, id, document, try fields.rows_of(
                context,
                form_defs,
                document,
            ));
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
                const live = if (domain.live) |of|
                    if (shape.preview) null else try of(session, def, row, document)
                else
                    null;
                const parks = row.changed or def.flow.is_live(row.status);
                const status = def.flow.find(row.status);
                const may = may_of(session, row);
                const version = full.version;
                const listed = try without_drafts(arena, full.scheduled);
                const scheduled = try scheduled_of(session, def, row, listed);
                const shown = shown_of(listed, scheduled, version);
                const draft = version > 0 and draft_on(full.scheduled, version);
                const compared: Compared = if (shown != null and shown.?.kept.version)
                    try compare_of(session, def, row, version)
                else
                    .{};
                const live_actions = try actions_of(session, def.flow, row, may);
                const actions = if (version > 0)
                    try version_actions(session, shown, draft)
                else
                    live_actions;
                const requested = try requested_of(session, def.flow, row, may);
                const suffix = if (version > 0)
                    try print(arena, "?version={d}", .{version})
                else
                    "";
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
                    .record_url = try print(arena, "{s}/{s}{s}", .{ back, row.id, suffix }),
                    .save_url = try print(arena, "{s}/{s}/save{s}", .{ back, row.id, suffix }),
                    .create_url = create_url,
                    .base_url = back,
                    .is_new = false,
                    .in_drawer = drawer,
                    .action_route = try print(arena, "{s}/{s}/action{s}", .{
                        back,
                        row.id,
                        suffix,
                    }),
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
                    .changed = if (version > 0) draft else row.changed,
                    .versions_href = versions_href,
                    .preview_href = preview_href,
                    .problems = problems,
                    .problems_title = shape.problems_title,
                    .actions = actions,
                    .has_destructive = has_destructive(actions),
                    .fields = field_rows,
                    .compare = compared.node,
                    .compare_combinations = compared.combinations,
                    .compare_label = if (compared.combinations.len > 0)
                        compared.combinations[0].label
                    else
                        "",
                    .parks = parks,
                    .preview = shape.preview,
                    .stacked = !drawer and
                        model.editor.field_of(def.editor, def.editor_config, def.fields) != null,
                    .focus = def.kind != .settings,
                    .aside = aside,
                    .live = if (version > 0) null else live,
                    .has_live = version == 0 and live != null,
                    .impact = null,
                    .dimensions = try pickers_of(session),
                    .markers = try with_changed(
                        session,
                        try markers_drawn(session, def.handle, document, row.id),
                        def,
                        row,
                        version,
                        document,
                    ),
                    .helps = try helps_drawn(session, def.handle, document),
                    .request_by = requested.by,
                    .request_label = requested.label,
                    .request_transition = requested.transition,
                    .request_may_approve = requested.may_approve,
                    .request_decline_label = requested.decline_label,
                    .may_schedule = if (comptime @hasDecl(operations, "TransitionAt"))
                        registry.SDK.may(&session.ctx, operations.TransitionAt)
                    else
                        false,
                    .schedule = try schedule_of(session, def, row, scheduled, listed, version),
                    .scheduled_count = @floatFromInt(scheduled.len),
                    .live_href = try print(arena, "{s}/{s}", .{ back, row.id }),
                    .versions_open = def.flow.is_live(row.status) or scheduled.len > 0,
                    .schedule_options = try schedule_options(
                        session,
                        live_actions,
                        version,
                        draft,
                        if (shown) |one| one.kept.version else false,
                    ),
                    .version_entry = if (version > 0) try print(arena, "{d}", .{version}) else "",
                    .version_label = if (shown) |one| one.item.label else "",
                    .version_when = if (shown) |one| one.item.when else "",
                    .version_note = if (shown) |one|
                        if (one.item.failed) one.item.problem else one.item.changes
                    else
                        "",
                    .version_failed = if (shown) |one| one.item.failed else false,
                    .version_move = if (shown) |one| !one.kept.version else false,
                    .version_at = if (shown) |one|
                        try std.mem.replaceOwned(u8, arena, one.item.when, " ", "T")
                    else
                        "",
                    .time_zone = (try site_zone(session)).name,
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

        /// The rows with the panels plugins draw under fields as their help (`Panel.field`),
        /// each in the plugin frame, told the record (none on a new one) and the field's value
        /// as the form holds it.
        fn with_panels(
            session: *Session,
            handle: []const u8,
            id: []const u8,
            document: ?Value,
            rows: []const fields.Row,
        ) Error![]const fields.Row {
            std.debug.assert(handle.len > 0);
            std.debug.assert(session.signed_in());

            const found = try frame_panels.for_type(session, handle);
            const helped = for (found) |panel| {
                if (panel.field.len > 0) {
                    break true;
                }
            } else false;

            if (!helped) {
                return rows;
            }

            const out = try session.arena.dupe(fields.Row, rows);

            for (out) |*row| {
                row.panels = try panels_under(session, found, row.name, id, document);
            }

            return out;
        }

        fn panels_under(
            session: *Session,
            found: []const frame_panels.Panel,
            field: []const u8,
            id: []const u8,
            document: ?Value,
        ) Error![]const FieldPanel {
            std.debug.assert(field.len > 0);
            std.debug.assert(session.signed_in());

            const frame_pages = @import("frame/pages.zig");
            var items: std.ArrayList(FieldPanel) = .empty;

            for (found) |panel| {
                if (!std.mem.eql(u8, panel.field, field)) {
                    continue;
                }

                // A long value is told once the frame says hello, not in its address.
                const whole = held_text(session.arena, document, panel.field) catch {
                    return error.OutOfMemory;
                };
                const held = if (whole.len > held_in_address_max) "" else whole;
                const own = try frame_pages.operations_of(session, panel.plugin);
                const src = try print(
                    session.arena,
                    "/admin/plugin/{s}/panels/{s}/frame?record={s}&type={s}&value={s}",
                    .{
                        panel.plugin,
                        panel.operation,
                        id,
                        panel.type,
                        try admin.query_value(session.arena, held),
                    },
                );

                try items.append(session.arena, .{
                    .label = panel.label,
                    .plugin = panel.plugin,
                    .src = src,
                    .operations = try std.mem.join(session.arena, ",", own),
                });
            }

            return items.items;
        }
    };
}

const held_in_address_max: u32 = 2048;
const frame_panels = @import("frame/panels.zig");
const FieldPanel = @typeInfo(@FieldType(fields.Row, "panels")).pointer.child;

/// A top-level field's value as the form holds it: its text, any other value as JSON;
/// empty for none.
fn held_text(arena: std.mem.Allocator, document: ?Value, field: []const u8) ![]const u8 {
    std.debug.assert(field.len > 0);

    const value = (document orelse return "").object.get(field) orelse return "";

    return switch (value) {
        .null => "",
        .string => |text| text,
        else => try std.json.Stringify.valueAlloc(arena, value, .{}),
    };
}

/// The status actions a document offers from where it is: publish, discard, every transition
/// its type's flow makes out of the current status, and, in the trash, destroy for whoever
/// may destroy.
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

    if (may.destroy and std.mem.eql(u8, status, model.flow.trashed)) {
        const label = try session.translated("Destroy for good", .{});

        try add_action(arena, &actions, "transition", "destroy", label, true);
    }

    mark_primary(actions.items);

    return actions.items;
}

/// What the person may do beyond writing: destroy, and put things live.
pub const May = struct {
    destroy: bool = false,
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

/// A scheduled entry as the editor says it.
const ScheduledItem = struct {
    entry: []const u8,
    /// When, on the site's clock: `2026-11-07 18:00`.
    when: []const u8,
    label: []const u8,
    /// The fields a version changes: `Title, Summary (pl)`.
    changes: []const u8,
    failed: bool,
    problem: []const u8,
    /// The first waiting one: the only one run now.
    next: bool,
};

/// The scheduled version (`?version=`) asked for, 0 for the record as it is.
fn version_of(session: *Session) i64 {
    std.debug.assert(session.signed_in());
    std.debug.assert(back_any.len > 0);

    const asked = admin.query_param(session, "version") orelse return 0;

    return @max(0, std.fmt.parseInt(i64, asked, 10) catch 0);
}

const back_any = "/admin";

/// The entry shown, read and as the timeline says it; null for the record as it is.
const ShownEntry = struct {
    kept: Scheduled,
    item: ScheduledItem,
};

fn shown_of(kept: []const Scheduled, items: []const ScheduledItem, version: i64) ?ShownEntry {
    std.debug.assert(kept.len == items.len);
    std.debug.assert(version >= 0);

    for (kept, items) |one, item| {
        if (one.entry == version) {
            return .{
                .kept = one,
                .item = item,
            };
        }
    }

    return null;
}

/// The action button over a scheduled change: with edits made on top of it, they go into
/// it (or are dropped, or scheduled on top from the menu); it goes live now with what it
/// builds on; a status change runs now when it is next. Any goes.
fn version_actions(session: *Session, shown: ?ShownEntry, draft: bool) Error![]const Action {
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    const one = shown orelse return &.{};
    var actions: std.ArrayList(Action) = .empty;
    const tr = session;

    if (one.kept.version and !one.item.failed) {
        if (draft) {
            const into = try tr.translated("Save into this one", .{});

            try add_action(arena, &actions, "do", "save_into", into, false);
        }

        const now = try tr.translated("Publish now", .{});

        try add_action(arena, &actions, "do", "publish_version", now, false);

        if (draft) {
            const discard = try tr.translated("Discard changes", .{});

            try add_action(arena, &actions, "do", "discard_draft", discard, false);
        }
    } else if (one.item.next) {
        try add_action(arena, &actions, "do", "run", try tr.translated("Run now", .{}), false);
    }

    if (actions.items.len > 0) {
        actions.items[0].primary = true;
    }

    try add_action(arena, &actions, "do", "unschedule", try tr.translated("Remove", .{}), true);

    return actions.items;
}

const ScheduleOption = views.RecordEditor.Schedule_optionsItem;

/// What Schedule… offers: on what is live, its unpublished changes and its status moves; on
/// a scheduled change, the edits made on top of it and the status moves after it.
fn schedule_options(
    session: *Session,
    live: []const Action,
    version: i64,
    draft: bool,
    change: bool,
) Error![]const ScheduleOption {
    std.debug.assert(version >= 0);
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    var out: std.ArrayList(ScheduleOption) = .empty;

    if (version > 0 and draft) {
        try out.append(arena, .{
            .value = "publish",
            .label = try session.translated("The changes made here", .{}),
        });
    }

    if (version > 0 and !change) {
        return out.items;
    }

    for (live) |item| {
        const publishes = std.mem.eql(u8, item.value, "publish");
        const moves = std.mem.eql(u8, item.name, "transition") or publishes;

        if (!moves or item.destructive or (version > 0 and publishes)) {
            continue;
        }

        try out.append(arena, .{
            .value = item.value,
            .label = item.label,
        });
    }

    return out.items;
}

/// Whether edits are kept on top of scheduled change `version`, waiting.
fn draft_on(kept: []const Scheduled, version: i64) bool {
    std.debug.assert(kept.len <= 1024);
    std.debug.assert(version >= 0);

    for (kept) |one| {
        if (std.mem.eql(u8, one.state, "draft") and one.base == version) {
            return true;
        }
    }

    return false;
}

/// What is scheduled, drafts left out.
fn without_drafts(arena: std.mem.Allocator, kept: []const Scheduled) Error![]const Scheduled {
    std.debug.assert(kept.len <= 1024);

    var out: std.ArrayList(Scheduled) = .empty;

    for (kept) |one| {
        if (!std.mem.eql(u8, one.state, "draft")) {
            try out.append(arena, one);
        }
    }

    return out.items;
}

const Marker = @import("../../operations/record/markers.zig").Marker;

/// The fields a scheduled change makes differ from its base, as `document` (the form as it
/// stands, saved or not) has them: each top-level field once.
fn changed_names(
    session: *Session,
    def: Def,
    row: Record,
    version: i64,
    document: Value,
) Error![]const []const u8 {
    std.debug.assert(version > 0);
    std.debug.assert(row.id.len > 0);

    const arena = session.arena;
    const ctx = &session.ctx;
    const found = versions_module.find(ctx, row.id, version) catch return &.{};
    const at = found orelse return &.{};
    const base = at.entries[at.index].base_id;
    const before = versions_module.projected(ctx, row, def, at.entries, base) catch return &.{};

    if (document != .object) {
        return &.{};
    }

    const changes = model.change_set.between(arena, before.document, document) catch {
        return error.OutOfMemory;
    };
    var names: std.ArrayList([]const u8) = .empty;

    for (changes.keys()) |key| {
        const name = model.dimension.split(key).name;
        const seen = for (names.items) |known| {
            if (std.mem.eql(u8, known, name)) {
                break true;
            }
        } else false;

        if (!seen) {
            try names.append(arena, name);
        }
    }

    return names.items;
}

/// A `Changed` marker beside each field a scheduled change changes, after `drawn`.
fn with_changed(
    session: *Session,
    drawn: []const views.RecordEditor.MarkersItem,
    def: Def,
    row: Record,
    version: i64,
    document: ?Value,
) Error![]const views.RecordEditor.MarkersItem {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(version >= 0);

    const shown = document orelse return drawn;

    if (version == 0) {
        return drawn;
    }

    const arena = session.arena;
    const names = try changed_names(session, def, row, version, shown);
    var out: std.ArrayList(views.RecordEditor.MarkersItem) = .empty;

    try out.appendSlice(arena, drawn);

    for (names) |name| {
        try out.append(arena, .{
            .field = name,
            .label = try session.translated("Changed", .{}),
            .group = "",
            .tone = "neutral",
            .dimension = "",
            .code = "",
            .current = "show",
            .href = "",
        });
    }

    return out.items;
}

/// The same for the editor asking again with the form as it stands (`document`, JSON).
fn changed_of_form(
    session: *Session,
    def: Def,
    id: []const u8,
    version: i64,
    document: []const u8,
) Error![]const Marker {
    std.debug.assert(id.len <= 128);
    std.debug.assert(version >= 0);

    if (version == 0 or id.len == 0) {
        return &.{};
    }

    const arena = session.arena;
    const row = store.records.get(session.ctx.db, arena, id) catch null;
    const found = row orelse return &.{};
    const parsed = @import("../../lib/json.zig").parse(Value, arena, document, .{
        .allocate = .alloc_always,
    }) catch return &.{};
    const names = try changed_names(session, def, found, version, parsed);
    const out = try arena.alloc(Marker, names.len);

    for (names, out) |name, *marker| {
        marker.* = .{
            .field = name,
            .label = try session.translated("Changed", .{}),
            .tone = "neutral",
        };
    }

    return out;
}

const compare = @import("compare.zig");

/// A scheduled change beside its base, one combination of its dimensions at a time (each it
/// changes; the first shown): each field as a visitor reads it there, as the base has it and
/// as the change makes it, what changed marked, the rest quieter.
const Compared = struct {
    node: ?admin.render.Node = null,
    combinations: []const views.RecordEditor.Compare_combinationsItem = &.{},
};

fn compare_of(session: *Session, def: Def, row: Record, version: i64) Error!Compared {
    std.debug.assert(version > 0);
    std.debug.assert(row.id.len > 0);

    const arena = session.arena;
    const ctx = &session.ctx;
    const found = (versions_module.find(ctx, row.id, version) catch null) orelse return .{};
    const entry = found.entries[found.index];
    const before = versions_module.projected(ctx, row, def, found.entries, entry.base_id) catch {
        return error.OutOfMemory;
    };
    const after = versions_module.shown(ctx, row, def, found.entries, version) catch {
        return error.OutOfMemory;
    };
    const changes = model.change_set.between(arena, before.document, after.document) catch {
        return error.OutOfMemory;
    };
    const dims = try varied_of(session, def);
    var sections: std.ArrayList(CompareSection) = .empty;
    var combinations: std.ArrayList(views.RecordEditor.Compare_combinationsItem) = .empty;

    for (try combinations_of(arena, changes)) |combination| {
        const pairs = try pairs_of(arena, dims, combination);
        const label = try combination_label(arena, dims, pairs);

        try sections.append(arena, .{
            .combination = combination,
            .rows = try rows_in(session, def, before.document, after.document, pairs),
        });
        try combinations.append(arena, .{
            .key = combination,
            .label = label,
        });
    }

    const rule = (try site_zone(session)).rule;
    const local = entry.due_at + zone.offset_ms(rule, entry.due_at);
    const when = model_time.datetime_local_text(arena, local) catch "";

    return .{
        .node = try admin.render.view(arena, views.RecordCompare, .{
            .base_label = try base_label_of(session, found.entries, entry),
            .base_live = entry.base_id == null,
            .change_label = try std.mem.replaceOwned(u8, arena, when, "T", " "),
            .sections = sections.items,
        }),
        .combinations = combinations.items,
    };
}

const CompareSection = views.RecordCompare.SectionsItem;
const CompareRow = @typeInfo(@FieldType(CompareSection, "rows")).pointer.child;

/// What the change builds on, as its column says it: `Live`, or that change's time.
fn base_label_of(
    session: *Session,
    entries: []const store.scheduled_changes.Entry,
    entry: store.scheduled_changes.Entry,
) Error![]const u8 {
    std.debug.assert(entry.id > 0);
    std.debug.assert(session.signed_in());

    const base = entry.base_id orelse return session.translated("Live", .{});
    const at = for (entries) |one| {
        if (one.id == base) {
            break one;
        }
    } else null;
    const on = at orelse return session.translated("Live", .{});
    const rule = (try site_zone(session)).rule;
    const local = on.due_at + zone.offset_ms(rule, on.due_at);
    const text = model_time.datetime_local_text(session.arena, local) catch "";

    return std.mem.replaceOwned(u8, session.arena, text, "T", " ");
}

/// Each combination the changed keys name, once, the main values first.
fn combinations_of(arena: std.mem.Allocator, changes: std.json.ObjectMap) Error![]const []const u8 {
    std.debug.assert(changes.count() <= 64 << 10);

    var out: std.ArrayList([]const u8) = .empty;

    for (changes.keys()) |key| {
        const combination = model.dimension.split(key).combination;
        const seen = for (out.items) |known| {
            if (std.mem.eql(u8, known, combination)) {
                break true;
            }
        } else false;

        if (seen) {
            continue;
        }

        if (combination.len == 0) {
            try out.insert(arena, 0, combination);
        } else {
            try out.append(arena, combination);
        }
    }

    return out.items;
}

/// A dimension the type's fields vary by, with its values, the main one first.
const VariedDimension = struct {
    name: []const u8,
    values: []const site_dimensions.Value,
};

fn varied_of(session: *Session, def: Def) Error![]const VariedDimension {
    std.debug.assert(def.fields.len <= model.field.fields_max);
    std.debug.assert(session.signed_in());

    var out: std.ArrayList(VariedDimension) = .empty;

    for (site_dimensions.all(&session.ctx)) |dimension| {
        const varies = for (def.fields) |field| {
            if (model.dimension.varies_by(field.dimensions, dimension.name)) {
                break true;
            }
        } else false;

        if (!varies) {
            continue;
        }

        const values = site_dimensions.values_of(&session.ctx, dimension) catch continue;

        if (values.len > 1) {
            try out.append(session.arena, .{
                .name = dimension.name,
                .values = values,
            });
        }
    }

    return out.items;
}

/// Every dims dimension at its code in `combination`, its main value where it names none.
fn pairs_of(
    arena: std.mem.Allocator,
    dims: []const VariedDimension,
    combination: []const u8,
) Error![]const model.dimension.Pair {
    std.debug.assert(dims.len <= model.dimension.dimensions_max);
    std.debug.assert(combination.len <= 1024);

    const parsed = model.dimension.parse(combination);
    const pairs = try arena.alloc(model.dimension.Pair, dims.len);

    for (dims, pairs) |dimension, *pair| {
        pair.* = .{
            .dimension = dimension.name,
            .code = if (parsed) |read| read.code_of(dimension.name) else "",
        };
    }

    return pairs;
}

/// A combination by its values' names: `Polski / B`, the main ones by theirs.
fn combination_label(
    arena: std.mem.Allocator,
    dims: []const VariedDimension,
    pairs: []const model.dimension.Pair,
) Error![]const u8 {
    std.debug.assert(dims.len == pairs.len);

    var labels: std.ArrayList([]const u8) = .empty;

    for (dims, pairs) |dimension, pair| {
        const value = for (dimension.values) |one| {
            const main = pair.code.len == 0 and one.main;

            if (main or std.mem.eql(u8, one.code, pair.code)) {
                break one;
            }
        } else dimension.values[0];

        try labels.append(arena, value.label);
    }

    return std.mem.join(arena, " / ", labels.items);
}

/// Each field in the form's order as a visitor reads it in `pairs`, before and after.
fn rows_in(
    session: *Session,
    def: Def,
    before: Value,
    after: Value,
    pairs: []const model.dimension.Pair,
) Error![]const CompareRow {
    std.debug.assert(before == .object and after == .object);
    std.debug.assert(pairs.len <= model.dimension.dimensions_max);

    const arena = session.arena;
    const resolve = model.dimension.resolve.resolve;
    const read_before = try resolve(arena, def.fields, before, pairs);
    const read_after = try resolve(arena, def.fields, after, pairs);
    const known = admin.kinds_of(session);
    var rows: std.ArrayList(CompareRow) = .empty;

    for (def.fields) |field| {
        if (model.field.is_layout(field.kind)) {
            continue;
        }

        const left = try compared_value(arena, read_before.object.get(field.name));
        const right = try compared_value(arena, read_after.object.get(field.name));

        try rows.append(arena, .{
            .label = try session.declared(field.label),
            .before = try compare.into(
                @typeInfo(@FieldType(CompareRow, "before")).pointer.child,
                arena,
                try compare.shown(arena, known, left),
            ),
            .after = try compare.into(
                @typeInfo(@FieldType(CompareRow, "after")).pointer.child,
                arena,
                try compare.shown(arena, known, right),
            ),
            .after_changes = try compare.segments_into(
                @typeInfo(@FieldType(CompareRow, "after_changes")).pointer.child,
                arena,
                try compare.changes(arena, "text", left, right),
            ),
            .changed = !compare.same(left, right),
        });
    }

    return rows.items;
}

/// A value as the comparison takes it: its JSON and its text; none for nothing.
fn compared_value(arena: std.mem.Allocator, value: ?Value) Error![]const compare.Value {
    const found = value orelse return &.{};

    std.debug.assert(found != .number_string);

    if (found == .null) {
        return &.{};
    }

    const json = std.json.Stringify.valueAlloc(arena, found, .{}) catch return error.OutOfMemory;
    const text = if (found == .string) found.string else json;
    const one = try arena.alloc(compare.Value, 1);

    one[0] = .{
        .json = json,
        .text = text,
    };

    return one;
}

const versions_module = @import("../../operations/record/versions.zig");

/// What a schedule is drawn from: the record, its changes as read and as said, the one shown.
const Tree = struct {
    session: *Session,
    def: Def,
    row: Record,
    entries: []const store.scheduled_changes.Entry,
    items: []const ScheduledItem,
    kept: []const Scheduled,
    current: i64,
};

/// The schedule as a timeline: what is live, then each change under the one it builds on,
/// soonest first among those on one base, each field from what it reads before to what it
/// sets.
fn schedule_of(
    session: *Session,
    def: Def,
    row: Record,
    items: []const ScheduledItem,
    kept: []const Scheduled,
    current: i64,
) Error!admin.render.Node {
    std.debug.assert(items.len == kept.len);
    std.debug.assert(row.id.len > 0);

    const arena = session.arena;
    const entries = store.scheduled_changes.of_record(session.ctx.db, arena, row.id) catch &.{};
    const tree: Tree = .{
        .session = session,
        .def = def,
        .row = row,
        .entries = entries,
        .items = items,
        .kept = kept,
        .current = current,
    };

    return admin.render.view(arena, views.ScheduleTimeline, .{
        .live_href = try print(arena, "/admin/content/{s}", .{row.id}),
        .live_current = current == 0,
        .children = try branch_of(tree, null, 0),
    });
}

/// The changes on `base` (null: what is live), each with what builds on it; null for none.
fn branch_of(tree: Tree, base: ?i64, depth: u32) Error!?admin.render.Node {
    std.debug.assert(depth <= tree.kept.len);
    std.debug.assert(tree.items.len == tree.kept.len);

    const arena = tree.session.arena;
    var nodes: std.ArrayList(admin.render.Node) = .empty;

    for (tree.kept, tree.items) |one, item| {
        const on: ?i64 = if (one.base > 0) one.base else null;

        if (!std.meta.eql(on, base)) {
            continue;
        }

        const href = try print(arena, "/admin/content/{s}?version={d}", .{
            tree.row.id,
            one.entry,
        });
        const stacked = if (depth < tree.kept.len)
            try branch_of(tree, one.entry, depth + 1)
        else
            null;

        try nodes.append(arena, try admin.render.view(arena, views.ScheduleItem, .{
            .href = href,
            .when = item.when,
            .label = item.label,
            .changed = item.changes,
            .current = one.entry == tree.current,
            .failed = item.failed,
            .problem = item.problem,
            .stacked = stacked,
        }));
    }

    if (nodes.items.len == 0) {
        return null;
    }

    return try admin.render.all(arena, nodes.items);
}

/// A key's field by its label, its combination's codes after it: `Title (pl, b)`.
fn key_label(session: *Session, def: Def, key: []const u8) Error![]const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(def.fields.len <= model.field.fields_max);

    const split = model.dimension.split(key);
    const label = for (def.fields) |field| {
        if (std.mem.eql(u8, field.name, split.name)) {
            break try session.declared(field.label);
        }
    } else split.name;
    const codes = try codes_of(session.arena, split.combination);

    if (codes.len == 0) {
        return label;
    }

    return print(session.arena, "{s} ({s})", .{ label, codes });
}

/// What is scheduled for the record, soonest first, as its timeline says it: when, on the
/// site's clock; what (a transition, or `Publish changes` with the fields it publishes); and
/// why one failed.
fn scheduled_of(
    session: *Session,
    def: Def,
    row: Record,
    scheduled: []const Scheduled,
) Error![]const ScheduledItem {
    std.debug.assert(row.id.len > 0);
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    const site = try site_zone(session);
    const items = try arena.alloc(ScheduledItem, scheduled.len);

    for (scheduled, items) |kept, *item| {
        const local = kept.at + zone.offset_ms(site.rule, kept.at);
        const shown = model_time.datetime_local_text(arena, local) catch "";
        const label = if (kept.version)
            try session.translated("Scheduled change", .{})
        else if (def.flow.named(kept.transition, row.status)) |target|
            try session.declared(target.label)
        else
            kept.transition;

        item.* = .{
            .entry = try print(arena, "{d}", .{kept.entry}),
            .when = std.mem.replaceOwned(u8, arena, shown, "T", " ") catch {
                return error.OutOfMemory;
            },
            .label = label,
            .changes = try changed_fields(session, def, kept),
            .failed = std.mem.eql(u8, kept.state, "failed"),
            .problem = kept.problem,
            .next = false,
        };
    }

    for (items) |*item| {
        if (!item.failed) {
            item.next = true;
            break;
        }
    }

    return items;
}

/// The fields a scheduled publish changes, by their labels (`Title (pl)`), and what goes
/// live when that changes: `Title, Summary (pl), Goes live`.
fn changed_fields(session: *Session, def: Def, kept: Scheduled) Error![]const u8 {
    std.debug.assert(kept.changes.len <= 64 << 10);
    std.debug.assert(session.signed_in());

    const arena = session.arena;
    var names: std.ArrayList([]const u8) = .empty;

    for (kept.changes) |key| {
        const split = model.dimension.split(key);
        const field = for (def.fields) |candidate| {
            if (std.mem.eql(u8, candidate.name, split.name)) {
                break candidate;
            }
        } else null;
        const label = if (field) |found| try session.declared(found.label) else split.name;
        const codes = try codes_of(arena, split.combination);
        const named = if (codes.len == 0)
            label
        else
            try print(arena, "{s} ({s})", .{ label, codes });

        try names.append(arena, named);
    }

    if (kept.held_back != null) {
        try names.append(arena, try session.translated("Goes live", .{}));
    }

    return std.mem.join(arena, ", ", names.items);
}

/// A combination's codes only: `language=pl,variation=b` as `pl, b`.
fn codes_of(arena: std.mem.Allocator, combination: []const u8) Error![]const u8 {
    std.debug.assert(combination.len <= 1024);

    var codes: std.ArrayList([]const u8) = .empty;
    var pairs = std.mem.splitScalar(u8, combination, ',');

    while (pairs.next()) |pair| {
        const at = std.mem.indexOfScalar(u8, pair, '=') orelse continue;

        try codes.append(arena, pair[at + 1 ..]);
    }

    return std.mem.join(arena, ", ", codes.items);
}

/// The site's time zone, its name and rule: what schedules are typed and shown in.
pub fn site_zone(session: *Session) Error!SiteZone {
    std.debug.assert(session.signed_in());
    std.debug.assert(jobs.zone_key.len > 0);

    // Unread, the site's clock is UTC, as it is with none chosen.
    const kept = store.settings.get(session.ctx.db, session.arena, jobs.zone_key) catch null;
    const name = kept orelse "UTC";

    return .{
        .name = name,
        .rule = zone.rule_of(name) orelse "UTC0",
    };
}

pub const SiteZone = struct {
    name: []const u8,
    rule: []const u8,
};

const zone = @import("../../lib/zone.zig");
const jobs = @import("../../sdk/jobs.zig");
const store = @import("../../store.zig");

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

    if (!kind.has.taxonomy or model.taxonomy.is_implicit(field)) {
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

    const others = site_dimensions.others(&session.ctx) catch return &.{};
    const base_url = try definitions.host_url_of(session);
    const out = try session.arena.alloc(fields.SlugPrefix, others.len);

    for (others, out) |value, *entry| {
        entry.* = .{
            .code = value.code,
            .prefix = try print(session.arena, "{s}{s}/{s}/", .{
                base_url,
                value.address,
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

/// The fields as the form draws and reads them: each varied field followed by its values
/// (`name@pl`) on a site with more than one.
pub const VariedOptions = struct {
    /// The record being edited: each combination's placeholder is its fallback.
    document: ?Value = null,
    /// Its type and id: a family's member (an A/B test) shows only on the fields its owner
    /// says, none on a record not made yet.
    type: []const u8 = "",
    id: []const u8 = "",
};

pub fn varied(
    session: *Session,
    defs: []const model.field.Def,
    options: VariedOptions,
) Error![]const model.field.Def {
    std.debug.assert(session.signed_in());
    std.debug.assert(defs.len <= model.field.fields_max);

    const site = try site_dimensions_of(session, options.type, options.id);

    return fields.dimensions.expanded(session.arena, defs, site, options.document);
}

/// The codes of the addressed dimension (a language) other than its main one; none on a
/// site with one.
pub fn other_codes(session: *Session) Error![]const []const u8 {
    std.debug.assert(session.signed_in());

    const others = site_dimensions.others(&session.ctx) catch return &.{};
    const codes = try session.arena.alloc([]const u8, others.len);

    for (others, codes) |value, *code| {
        code.* = value.code;
    }

    return codes;
}

/// The site's dimensions with their codes other than the main one, highest priority first:
/// what the form makes each varied field's combinations of.
fn site_dimensions_of(
    session: *Session,
    type_name: []const u8,
    id: []const u8,
) Error![]const fields.dimensions.SiteDimension {
    std.debug.assert(session.signed_in());

    var out: std.ArrayList(fields.dimensions.SiteDimension) = .empty;
    const on_record = try site_dimensions.of_record(&session.ctx, type_name, id);

    for (on_record) |on| {
        const dimension = on.setting;
        const values = site_dimensions.values_of(&session.ctx, dimension) catch continue;
        var codes: std.ArrayList([]const u8) = .empty;

        for (values) |value| {
            if (!value.main) {
                try codes.append(session.arena, value.code);
            }
        }

        if (codes.items.len > 0) {
            try out.append(session.arena, .{
                .name = dimension.name,
                .codes = codes.items,
                .only = on.fields,
            });
        }
    }

    return out.items;
}

/// The editor's pickers: each dimension with more than one value, in its read option's word
/// (its field option's when it has none), its values the main one first under an empty code.
fn pickers_of(session: *Session) Error![]const views.RecordEditor.DimensionsItem {
    std.debug.assert(session.signed_in());

    const Item = views.RecordEditor.DimensionsItem;
    const Shown = @typeInfo(@FieldType(Item, "values")).pointer.child;
    var out: std.ArrayList(Item) = .empty;

    for (site_dimensions.all(&session.ctx)) |dimension| {
        const values = site_dimensions.values_of(&session.ctx, dimension) catch continue;

        if (values.len < 2) {
            continue;
        }

        const items = try session.arena.alloc(Shown, values.len);

        for (values, items) |value, *item| {
            item.* = .{
                .code = if (value.main) "" else value.code,
                .label = value.label,
            };
        }

        const word = if (dimension.read.label.len > 0)
            dimension.read.label
        else
            dimension.field.label;

        try out.append(session.arena, .{
            .name = dimension.name,
            .param = if (dimension.param.len > 0) dimension.param else dimension.name,
            .label = try session.declared(word),
            .values = items,
        });
    }

    return out.items;
}

/// The site's languages for the editor's switch, the main one first under an empty code.
pub fn languages_of(comptime Item: type, session: *Session) Error![]const Item {
    std.debug.assert(session.signed_in());

    const dimension = site_dimensions.setting(&session.ctx) orelse return &.{};
    const listed = site_dimensions.listed(&session.ctx) catch return &.{};
    const items = try session.arena.alloc(Item, listed.len);

    // Each as the part of a key it is: `language=pl`; the main one empty.
    for (listed, items) |value, *item| {
        item.* = .{
            .code = if (value.main)
                ""
            else
                try std.fmt.allocPrint(session.arena, "{s}={s}", .{ dimension.name, value.code }),
            .label = value.label,
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
