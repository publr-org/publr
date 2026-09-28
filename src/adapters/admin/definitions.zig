//! The definitions of a domain in the admin: the list, and a definition's head (names,
//! handle, who may read it). Content types and taxonomies are the two instantiations
//! (`types.zig`, `taxonomies.zig`); the pages are the same, the operations and the
//! addresses differ.
const std = @import("std");
const admin = @import("../admin.zig");
const registry = @import("../../server/registry.zig");
const model = @import("../../model.zig");
const slugs = @import("../../lib/text.zig");

const Request = admin.Request;
const Response = admin.Response;
const Context = admin.Context;
const Error = admin.Error;
const Form = admin.Form;
const Session = admin.Session;
const views = admin.views;
const Def = model.content_type.Def;
const Kind = model.content_type.Kind;
const room_text = @import("type_fields/rules.zig").room_text;
const values_of = @import("type_fields/settings.zig").values_of;
const content_types = @import("../../operations/content_type.zig");
const template_module = @import("../../template.zig");
const Routed = views.TypeForm.Applies_routedItem;
const Other = views.TypeForm.Applies_otherItem;

pub const Domain = struct {
    /// `/admin/types`, `/admin/taxonomies`.
    base: []const u8,
    /// `Content types`, `Taxonomies`.
    title: []const u8,
    /// `content type`, `taxonomy`.
    noun: []const u8,
    /// The input field naming a definition: `type`, `taxonomy`.
    key: []const u8,
    /// The list output's field: `types`, `taxonomies`.
    plural: []const u8,
    /// The operations module: `Create`, `Update`, `Get`, `List`, `Delete`, `Validate`.
    operations: type,
    is_taxonomy: bool,
    fixed_kind: ?Kind = null,

    /// `content types`, `taxonomies`: the title, lowercased.
    pub fn plural_title(comptime domain: Domain) []const u8 {
        comptime std.debug.assert(domain.title.len > 0);
        comptime std.debug.assert(domain.noun.len > 0);

        return comptime blk: {
            var lowered: [domain.title.len]u8 = undefined;

            for (domain.title, 0..) |char, index| {
                lowered[index] = std.ascii.toLower(char);
            }

            const copy = lowered;
            break :blk &copy;
        };
    }

    pub fn empty_description(comptime domain: Domain) []const u8 {
        comptime std.debug.assert(domain.noun.len > 0);
        comptime std.debug.assert(domain.base.len > 0);

        return if (domain.fixed_kind == .settings)
            "Define a settings section, then add the fields your editors can configure."
        else if (domain.fixed_kind == .component)
            "Create a reusable set of fields."
        else if (domain.is_taxonomy)
            "A taxonomy is a set of terms records are filed under: categories, tags. " ++
                "Create the first one."
        else
            "A content type is a name and a list of fields. Create the first one.";
    }
};

/// What the head's own fields were refused for, shown under each; the rest listed above.
const HeadErrors = struct {
    name: []const u8 = "",
    handle: []const u8 = "",
    description: []const u8 = "",
    rest: []const model.field.Problem = &.{},
};

/// The fields a new definition starts with: a taxonomy's terms have a name and a slug; a
/// content type accessible via URL starts with a slug field.
const slug_field = [_]model.field.Def{
    .{ .name = "slug", .label = "Slug", .kind = "slug" },
};
const term_fields = [_]model.field.Def{
    .{ .name = "name", .label = "Name", .kind = "string", .required = true },
    .{ .name = "slug", .label = "Slug", .kind = "slug", .options = .{ .source = "name" } },
    .{ .name = "description", .label = "Description", .kind = "text" },
};

/// An operation's input with the definition under the domain's key, the rest from
/// `extra` or the field's default.
pub fn keyed(comptime In: type, comptime key: []const u8, value: []const u8, extra: anytype) In {
    comptime std.debug.assert(@hasField(In, key));
    std.debug.assert(value.len > 0);

    var in: In = undefined;

    inline for (std.meta.fields(In)) |info| {
        if (comptime std.mem.eql(u8, info.name, key)) {
            @field(in, info.name) = value;
        } else if (comptime @hasField(@TypeOf(extra), info.name)) {
            @field(in, info.name) = @field(extra, info.name);
        } else if (comptime info.defaultValue()) |fallback| {
            @field(in, info.name) = fallback;
        } else {
            @compileError("no value for " ++ @typeName(In) ++ "." ++ info.name);
        }
    }

    return in;
}

pub fn Pages(comptime domain: Domain) type {
    return struct {
        const operations = domain.operations;
        const back = domain.base;
        const empty_def: Def = .{ .handle = "", .name = "", .fields = &.{} };

        pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .get or request.method() == .head);
            std.debug.assert(ctx.user_data != null);

            var session = try admin.require(request, response, ctx) orelse return;
            const listed = registry.SDK.dispatch(&session.ctx, operations.List, .{}) catch |err| {
                return admin.fail(&session, err, "/admin");
            };
            var items: std.ArrayList(views.Types.TypesItem) = .empty;

            for (@field(listed, domain.plural)) |summary| {
                if (domain.fixed_kind) |kind| {
                    if (summary.kind != kind) continue;
                }
                const href = try print(session.arena, "{s}/{s}", .{ back, summary.handle });
                const content_href = if (summary.kind == .component)
                    ""
                else if (domain.is_taxonomy)
                    href
                else if (summary.kind == .settings)
                    try print(session.arena, "/admin/settings/{s}", .{summary.handle})
                else
                    try print(session.arena, "/admin/content?type={s}", .{summary.handle});
                const owner = if (summary.system) summary.owner else "";

                items.append(session.arena, .{
                    .href = href,
                    .name = summary.name,
                    .handle = summary.handle,
                    .kind = kind_label(summary.kind),
                    .visibility = if (summary.public) "public" else "private",
                    .owner = owner,
                    .fields = summary.fields,
                    .content_href = content_href,
                }) catch return error.OutOfMemory;
            }

            const shell = admin.shell_of(&session);

            try admin.render.page(response, session.arena, .ok, views.Types, .{
                .user_name = shell.user_name,
                .user_email = shell.user_email,
                .can_structure = shell.can_structure,
                .can_settings = shell.can_settings,
                .csrf = shell.csrf,
                .title = domain.title,
                .new_href = back ++ "/new",
                .new_label = "New " ++ domain.noun,
                .empty_title = comptime ("No " ++ domain.plural_title() ++ " yet"),
                .empty_description = domain.empty_description(),
                .show_kind = !domain.is_taxonomy and domain.fixed_kind == null,
                .manage_label = if (domain.is_taxonomy) "Terms" else "Manage",
                .types = items.items,
            });
        }

        fn kind_label(kind: Kind) []const u8 {
            std.debug.assert(@typeInfo(Kind).@"enum".fields.len == 3);
            std.debug.assert(back.len > 0);

            return switch (kind) {
                .record => "Record type",
                .settings => "Settings",
                .component => "Component",
            };
        }

        pub fn new_page(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .get or request.method() == .head);
            std.debug.assert(ctx.user_data != null);

            var session = try admin.require(request, response, ctx) orelse return;
            const wanted = admin.query_param(&session, "kind") orelse "record";
            var def = empty_def;

            def.kind = domain.fixed_kind orelse (std.meta.stringToEnum(
                Kind,
                wanted,
            ) orelse .record);

            try render_form(&session, def, null, &.{});
        }

        pub fn settings_page(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .get or request.method() == .head);
            std.debug.assert(ctx.user_data != null);

            var session = try admin.require(request, response, ctx) orelse return;
            const handle = try admin.param(&session, "handle", back) orelse return;
            const got = try load(&session, handle) orelse return;

            try render_form(&session, got.definition, got.definition.handle, &.{});
        }

        /// The definition, or a not-found page.
        pub fn load(session: *Session, handle: []const u8) Error!?operations.Get.Out {
            std.debug.assert(handle.len > 0);
            std.debug.assert(session.signed_in());

            const in = keyed(operations.Get.In, domain.key, handle, .{});

            const got = registry.SDK.dispatch(&session.ctx, operations.Get, in) catch |err| {
                try admin.fail(session, err, back);

                return null;
            };

            if (domain.fixed_kind) |kind| {
                if (got.definition.kind != kind) {
                    try admin.fail(session, error.NotFound, back);
                    return null;
                }
            }

            return got;
        }

        /// The head form: for a new definition (`existing_handle` null) or an existing
        /// one's settings, with what the last post was refused for, if it was.
        fn render_form(
            session: *Session,
            def: Def,
            existing_handle: ?[]const u8,
            problems: []const model.field.Problem,
        ) Error!void {
            std.debug.assert(session.signed_in());
            std.debug.assert(session.response.body.len == 0);

            const arena = session.arena;
            const is_new = existing_handle == null;
            const action = if (existing_handle) |handle|
                try print(arena, "{s}/{s}/update", .{ back, handle })
            else
                back ++ "/create";
            const delete_action: ?[]const u8 = if (existing_handle) |handle|
                try print(arena, "{s}/{s}/delete", .{ back, handle })
            else
                null;
            const back_href: ?[]const u8 = if (existing_handle) |handle|
                try print(arena, "{s}/{s}", .{ back, handle })
            else
                null;
            const shell = admin.shell_of(session);
            const errors = try head_errors(arena, problems);
            const limits = model.content_type;
            const applicable: Applicable = if (domain.is_taxonomy)
                applies_of(session, def) catch |err| return admin.fail(session, err, back)
            else
                .{};

            try admin.render.page(session.response, arena, .ok, views.TypeForm, .{
                .user_name = shell.user_name,
                .user_email = shell.user_email,
                .can_structure = shell.can_structure,
                .can_settings = shell.can_settings,
                .csrf = shell.csrf,
                .title = if (is_new) "New " ++ domain.noun else def.name,
                .crumb_label = domain.title,
                .crumb_href = back,
                .noun = domain.noun,
                .back_label = if (domain.is_taxonomy) "Terms" else "Fields",
                .action = action,
                .is_new = is_new,
                .choose_kind = domain.fixed_kind == null,
                .problems = try problem_items(arena, errors.rest),
                .back_href = back_href,
                .system = def.system,
                .owner = def.owner,
                .handle = def.handle,
                .name = def.name,
                .description = def.description,
                .name_count = try room_text(arena, def.name.len, limits.name_len_max),
                .handle_count = try room_text(arena, def.handle.len, limits.handle_len_max),
                .description_count = try room_text(
                    arena,
                    def.description.len,
                    limits.description_len_max,
                ),
                .name_error = errors.name,
                .handle_error = errors.handle,
                .description_error = errors.description,
                .url = def.url,
                .has_url = def.url.len > 0,
                .is_taxonomy = domain.is_taxonomy,
                .hierarchical = def.hierarchical,
                .single = def.single,
                .applies_routed = applicable.routed,
                .applies_other = applicable.other,
                .show_all_types = any_selected(applicable.other),
                .is_record = def.kind == .record,
                .is_settings = def.kind == .settings,
                .is_component = def.kind == .component,
                .base_url = try host_url_of(session),
                .visibility = if (def.public) "public" else "private",
                .is_public = def.public,
                .delete_action = delete_action,
            });
        }

        pub fn create(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .post);
            std.debug.assert(ctx.user_data != null);

            var post = try admin.accept(request, response, ctx, back) orelse return;
            var session = &post.session;
            const form = &post.form;

            var def = try head_of(session.arena, form, empty_def);

            if (domain.is_taxonomy) {
                def.title_field = "name";
                def.fields = &term_fields;
            } else if (def.url.len > 0) {
                def.fields = &slug_field;
            }

            const definition = model.content_type.encode(session.arena, def) catch {
                return error.OutOfMemory;
            };
            const created = registry.SDK.dispatch(&session.ctx, operations.Create, .{
                .definition = definition,
            }) catch |err| {
                return render_form(session, def, null, try problems_of(session, err, definition));
            };
            const location = try print(session.arena, "{s}/{s}", .{ back, created.handle });

            try response.redirect(.see_other, location);
        }

        pub fn update(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .post);
            std.debug.assert(ctx.user_data != null);

            var post = try admin.accept(request, response, ctx, back) orelse return;
            var session = &post.session;
            const form = &post.form;
            const handle = try admin.param(session, "handle", back) orelse return;
            const got = try load(session, handle) orelse return;

            if (got.definition.system) {
                return admin.fail(session, error.Denied, back);
            }

            const def = try head_of(session.arena, form, got.definition);
            const definition = model.content_type.encode(session.arena, def) catch {
                return error.OutOfMemory;
            };
            const in = keyed(operations.Update.In, domain.key, handle, .{
                .definition = definition,
            });
            const updated = registry.SDK.dispatch(&session.ctx, operations.Update, in) catch |err| {
                return render_form(session, def, handle, try problems_of(session, err, definition));
            };
            const moved = try print(session.arena, "{s}/{s}", .{ back, updated.handle });

            try response.redirect(.see_other, moved);
        }

        /// The head of the form over `base`: kind, names, handle (made from the name when
        /// empty), visibility. Fields and everything the form does not show stay as they
        /// are. A taxonomy has no kind and no URL; it is public or not, and hierarchical
        /// or flat.
        fn head_of(arena: std.mem.Allocator, form: *const Form, base: Def) Error!Def {
            std.debug.assert(form.len <= admin.form_pairs_max);
            std.debug.assert(base.fields.len <= model.field.fields_max);

            var def = base;
            const name = form.text("name") orelse "";
            const has_url = form.get("has_url") != null;

            def.name = name;
            def.description = form.text("description") orelse "";
            def.handle = form.text("handle") orelse try handle_of(arena, name);

            if (domain.is_taxonomy) {
                def.kind = .record;
                def.url = "";
                def.hierarchical = form.get("hierarchical") != null;
                def.public = form.get("public") != null;
                def.single = form.get("single") != null;
                def.applies_to = try values_of(arena, form, "applies_to");

                return def;
            }

            def.kind = domain.fixed_kind orelse
                (std.meta.stringToEnum(Kind, form.text("kind") orelse "") orelse base.kind);
            const routed = has_url and def.kind == .record;

            def.url = if (routed) form.text("url") orelse def.handle else "";
            // A record type is on the site when it has a URL; a settings type's one
            // record is site content the templates read; a component has no records.
            def.public = switch (def.kind) {
                .record => def.url.len > 0,
                .settings => form.get("public") != null,
                .component => false,
            };

            return def;
        }

        pub fn delete(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .post);
            std.debug.assert(ctx.user_data != null);

            var post = try admin.accept(request, response, ctx, back) orelse return;
            var session = &post.session;
            const form = &post.form;
            const handle = try admin.param(session, "handle", back) orelse return;
            _ = try load(session, handle) orelse return;
            const force = form.get("force") != null;
            const in = keyed(operations.Delete.In, domain.key, handle, .{ .force = force });

            _ = registry.SDK.dispatch(&session.ctx, operations.Delete, in) catch |err| {
                return admin.fail(session, err, back);
            };

            try response.redirect(.see_other, back);
        }

        /// A refused definition: what is wrong with it, as problems to show beside the
        /// form. An invalid definition lists every problem; any other refusal is one line.
        pub fn problems_of(
            session: *Session,
            err: anyerror,
            definition: []const u8,
        ) Error![]const model.field.Problem {
            std.debug.assert(definition.len > 0);
            std.debug.assert(@errorName(err).len > 0);

            if (err == error.OutOfMemory) {
                return error.OutOfMemory;
            }

            if (err != error.Invalid) {
                const one = try session.arena.alloc(model.field.Problem, 1);
                const message: []const u8 = switch (err) {
                    error.Conflict => "another " ++ domain.noun ++ " has this handle, or " ++
                        "content holds values the change would lose",
                    error.Denied => comptime ("you may not change " ++ domain.plural_title()),
                    else => @errorName(err),
                };

                one[0] = .{ .path = "", .message = message };

                return one;
            }

            const checked = registry.SDK.dispatch(&session.ctx, operations.Validate, .{
                .definition = definition,
            }) catch return error.OutOfMemory;

            return checked.problems;
        }
    };
}

fn any_selected(items: []const Other) bool {
    std.debug.assert(items.len <= model.taxonomy.applies_max);
    std.debug.assert(slug_field.len == 1);

    for (items) |item| {
        if (item.selected) {
            return true;
        }
    }

    return false;
}

/// Whether records of a type have pages of their own: a page template of a loaded app reads
/// the type's entry (`posts/[slug].publr`); without apps, whether the definition claims an
/// address.
fn has_pages(session: *Session, handle: []const u8) !bool {
    std.debug.assert(handle.len > 0);
    std.debug.assert(session.signed_in());

    if (session.project.apps.len == 0) {
        var scratch = std.heap.ArenaAllocator.init(session.arena);
        defer scratch.deinit();
        var ctx = session.ctx;
        ctx.arena = scratch.allocator();
        const row = try content_types.find_raw(&ctx, handle);

        return row != null and row.?.def.url.len > 0;
    }

    for (session.project.apps) |*app| {
        const program = app.program orelse continue;

        if (try template_module.impact.has_entry_page(session.arena, program, handle)) {
            return true;
        }
    }

    return false;
}

/// The record types a taxonomy may apply to, the chosen ones ticked: the ones with pages
/// of their own on the site (`routed`), or the rest.
const Applicable = struct { routed: []const Routed = &.{}, other: []const Other = &.{} };

fn applies_of(session: *Session, def: Def) !Applicable {
    std.debug.assert(session.signed_in());
    std.debug.assert(def.applies_to.len <= model.taxonomy.applies_max);

    const listed = try registry.SDK.dispatch(&session.ctx, content_types.List, .{});
    var routed: std.ArrayList(Routed) = .empty;
    var other: std.ArrayList(Other) = .empty;

    for (listed.types) |summary| {
        if (summary.kind != .record) {
            continue;
        }

        const selected = model.taxonomy.applies(def, summary.handle);

        if (try has_pages(session, summary.handle)) {
            try routed.append(session.arena, .{
                .value = summary.handle,
                .label = summary.name,
                .selected = selected,
            });
        } else {
            try other.append(session.arena, .{
                .value = summary.handle,
                .label = summary.name,
                .selected = selected,
            });
        }
    }

    return .{ .routed = routed.items, .other = other.items };
}

/// The problems of the name, the handle and the description go under their fields (the
/// first of each); everything else stays in the list above the form.
fn head_errors(arena: std.mem.Allocator, problems: []const model.field.Problem) Error!HeadErrors {
    std.debug.assert(problems.len <= model.field.problems_max);
    std.debug.assert(slug_field.len == 1);

    var errors: HeadErrors = .{};
    var rest: std.ArrayList(model.field.Problem) = .empty;

    for (problems) |problem| {
        if (std.mem.eql(u8, problem.path, "name") and errors.name.len == 0) {
            errors.name = problem.message;
        } else if (std.mem.eql(u8, problem.path, "handle") and errors.handle.len == 0) {
            errors.handle = problem.message;
        } else if (std.mem.eql(u8, problem.path, "description") and errors.description.len == 0) {
            errors.description = problem.message;
        } else {
            rest.append(arena, problem) catch return error.OutOfMemory;
        }
    }

    errors.rest = rest.items;

    return errors;
}

fn problem_items(
    arena: std.mem.Allocator,
    problems: []const model.field.Problem,
) Error![]const views.TypeForm.ProblemsItem {
    std.debug.assert(problems.len <= model.field.problems_max);
    std.debug.assert(term_fields.len == 3);

    const items = try arena.alloc(views.TypeForm.ProblemsItem, problems.len);

    for (problems, 0..) |problem, index| {
        items[index] = .{ .path = problem.path, .message = problem.message };
    }

    return items;
}

/// Where the admin is, as the browser reached it: the scheme a proxy reports, else plain
/// http, and the host the request named.
pub fn host_url_of(session: *const Session) Error![]const u8 {
    std.debug.assert(session.signed_in());
    std.debug.assert(slug_field.len == 1);

    const host = session.request.header("host") orelse "localhost";
    const forwarded = session.request.header("x-forwarded-proto") orelse "http";
    const scheme = if (std.mem.eql(u8, forwarded, "https")) "https" else "http";

    return print(session.arena, "{s}://{s}", .{ scheme, host });
}

/// A handle made from a display name: `Simple article` becomes `simple_article`.
pub fn handle_of(arena: std.mem.Allocator, name: []const u8) Error![]const u8 {
    std.debug.assert(name.len <= 64 << 10);
    std.debug.assert(slugs.slug_len_max > 0);

    const slug = slugs.slugify(arena, name) catch return error.OutOfMemory;
    const handle = arena.dupe(u8, slug) catch return error.OutOfMemory;

    std.mem.replaceScalar(u8, handle, '-', '_');

    return handle;
}

pub fn print(
    arena: std.mem.Allocator,
    comptime template: []const u8,
    args: anytype,
) Error![]const u8 {
    std.debug.assert(template.len > 0);
    std.debug.assert(slug_field.len == 1);

    return std.fmt.allocPrint(arena, template, args) catch error.OutOfMemory;
}

test "the head's own problems go under their fields, the rest stay listed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const problems = [_]model.field.Problem{
        .{ .path = "name", .message = "name must be 1 to 50 characters" },
        .{ .path = "url", .message = "a type with a url is public" },
        .{ .path = "handle", .message = "handle must be [a-z][a-z0-9_]*, up to 64 characters" },
        .{ .path = "name", .message = "second, kept in the list" },
    };
    const errors = try head_errors(arena_state.allocator(), &problems);
    try std.testing.expectEqualStrings("name must be 1 to 50 characters", errors.name);
    try std.testing.expect(errors.handle.len > 0);
    try std.testing.expectEqual(@as(usize, 0), errors.description.len);
    try std.testing.expectEqual(@as(usize, 2), errors.rest.len);
    try std.testing.expectEqualStrings("url", errors.rest[0].path);
}

test "handles are made from names; an input is keyed under the domain's name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings("simple_article", try handle_of(arena, "Simple article"));
    try std.testing.expectEqualStrings("faq_2", try handle_of(arena, " FAQ (2) "));
    try std.testing.expectEqualStrings("record", try handle_of(arena, ""));

    const In = struct { taxonomy: []const u8, definition: []const u8, drop_content: bool = false };
    const in = keyed(In, "taxonomy", "topics", .{ .definition = "{}" });
    try std.testing.expectEqualStrings("topics", in.taxonomy);
    try std.testing.expectEqualStrings("{}", in.definition);
    try std.testing.expect(!in.drop_content);
}
