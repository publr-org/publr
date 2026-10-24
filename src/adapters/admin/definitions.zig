//! The definitions of a domain in the admin: the list, and a definition's head (names,
//! handle, who may read it). Content types and taxonomies are the two instantiations
//! (`types.zig`, `taxonomies.zig`); the pages are the same, the operations and the
//! addresses differ.
const std = @import("std");
const sdk_operation = @import("../../sdk/operation.zig");
const type_editor = @import("type_editor.zig");
const type_placement = @import("type_placement.zig");
const type_names = @import("type_names.zig");
const variants = @import("../../operations/variants.zig");
const admin = @import("../admin.zig");
const settings_nav = @import("settings_nav.zig");
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
const Choice = views.TypeForm.Taxonomy_choicesItem;
const User = views.TypeForm.Used_byItem;
const on_type = @import("../../operations/taxonomy/on_type.zig");
const taxonomy_operations = @import("../../operations/taxonomy.zig");

pub const Domain = struct {
    /// `/admin/types`, `/admin/structure/taxonomies`.
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

    /// What the domain's pages say of it, in the person's language.
    pub fn words(comptime domain: Domain, session: *const Session) Error!Words {
        comptime std.debug.assert(domain.noun.len > 0);
        std.debug.assert(session.signed_in());

        if (domain.fixed_kind == .settings) {
            return settings_words(session);
        }

        if (domain.fixed_kind == .component) {
            return component_words(session);
        }

        if (domain.is_taxonomy) {
            return taxonomy_words(session);
        }

        return content_type_words(session);
    }
};

const Words = struct {
    title: []const u8,
    new_label: []const u8,
    empty_title: []const u8,
    empty_description: []const u8,
    conflict: []const u8,
    denied: []const u8,
};

fn content_type_words(session: *const Session) Error!Words {
    std.debug.assert(session.signed_in());

    const conflict = try session.translated(
        "another content type has this handle, or content holds values the change would lose",
        .{},
    );

    return .{
        .title = try session.translated("Content types", .{}),
        .new_label = try session.translated("New content type", .{}),
        .empty_title = try session.translated("No content types yet", .{}),
        .empty_description = try session.translated(
            "A content type is a name and a list of fields. Create the first one.",
            .{},
        ),
        .conflict = conflict,
        .denied = try session.translated("you may not change content types", .{}),
    };
}

fn taxonomy_words(session: *const Session) Error!Words {
    std.debug.assert(session.signed_in());

    const conflict = try session.translated(
        "another taxonomy has this handle, or content holds values the change would lose",
        .{},
    );
    const what = try session.translated(
        "A taxonomy is a set of terms records are filed under: categories, tags.",
        .{},
    );
    const first = try session.translated("Create the first one.", .{});

    return .{
        .title = try session.translated("Taxonomies", .{}),
        .new_label = try session.translated("New taxonomy", .{}),
        .empty_title = try session.translated("No taxonomies yet", .{}),
        .empty_description = try std.fmt.allocPrint(session.arena, "{s} {s}", .{ what, first }),
        .conflict = conflict,
        .denied = try session.translated("you may not change taxonomies", .{}),
    };
}

fn settings_words(session: *const Session) Error!Words {
    std.debug.assert(session.signed_in());

    const conflict = try session.translated(
        "another settings section has this handle, or content holds values the change would lose",
        .{},
    );
    const empty_description = try session.translated(
        "Define a settings section, then add the fields your editors can configure.",
        .{},
    );

    return .{
        .title = try session.translated("Settings", .{}),
        .new_label = try session.translated("New settings section", .{}),
        .empty_title = try session.translated("No settings yet", .{}),
        .empty_description = empty_description,
        .conflict = conflict,
        .denied = try session.translated("you may not change settings", .{}),
    };
}

fn component_words(session: *const Session) Error!Words {
    std.debug.assert(session.signed_in());

    const conflict = try session.translated(
        "another component has this handle, or content holds values the change would lose",
        .{},
    );

    return .{
        .title = try session.translated("Components", .{}),
        .new_label = try session.translated("New component", .{}),
        .empty_title = try session.translated("No components yet", .{}),
        .empty_description = try session.translated("Create a reusable set of fields.", .{}),
        .conflict = conflict,
        .denied = try session.translated("you may not change components", .{}),
    };
}

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
    .{
        .name = "slug",
        .label = "Slug",
        .kind = "slug",
    },
};
const term_fields = [_]model.field.Def{
    .{
        .name = "name",
        .label = "Name",
        .kind = "string",
        .validation = .{
            .required = true,
        },
    },
    .{
        .name = "slug",
        .label = "Slug",
        .kind = "slug",
        .options = .{
            .source = "name",
        },
    },
    .{
        .name = "description",
        .label = "Description",
        .kind = "text",
    },
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

/// Definitions a list page shows at a time.
const page_size: u32 = 50;

pub fn Pages(comptime domain: Domain) type {
    return struct {
        const operations = domain.operations;
        const back = domain.base;
        const empty_def: Def = .{
            .handle = "",
            .name = "",
            .fields = &.{},
        };

        pub fn list(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .get or request.method() == .head);
            std.debug.assert(ctx.user_data != null);

            var session = try admin.require(request, response, ctx) orelse return;
            const offset = admin.pager.offset_of(&session);
            const listed = registry.SDK.dispatch(&session.ctx, operations.List, .{
                .offset = offset,
                .limit = page_size,
            }) catch |err| {
                return admin.fail(&session, err, "/admin");
            };
            var items: std.ArrayList(views.Types.TypesItem) = .empty;

            for (@field(listed, domain.plural)) |summary| {
                if (domain.fixed_kind) |kind| {
                    if (summary.kind != kind) continue;
                }

                // Files are managed where their owner draws them, not as a type.
                if (summary.kind == .media) continue;
                const href = try print(session.arena, "{s}/{s}", .{ back, summary.handle });
                const content_href = if (summary.kind == .component)
                    ""
                else if (domain.is_taxonomy)
                    try print(session.arena, "{s}/terms", .{href})
                else if (summary.kind == .settings)
                    try print(session.arena, "/admin/settings/{s}", .{summary.handle})
                else
                    try print(session.arena, "/admin/content?type={s}", .{summary.handle});
                const owner = if (summary.system) summary.owner else "";

                items.append(session.arena, .{
                    .href = href,
                    .name = summary.name,
                    .handle = summary.handle,
                    .kind = try kind_label(&session, summary.kind),
                    .visibility = if (summary.public) "public" else "private",
                    .owner = owner,
                    .fields = summary.fields,
                    .content_href = content_href,
                }) catch return error.OutOfMemory;
            }

            const shown: u32 = @intCast(@field(listed, domain.plural).len);
            const pages = try admin.pager.links(
                session.arena,
                back,
                offset,
                shown,
                listed.total,
                page_size,
            );

            const words = try domain.words(&session);

            try admin.screen(&session, .ok, views.Types, .{
                .title = words.title,
                .new_href = back ++ "/new",
                .new_label = words.new_label,
                .empty_title = words.empty_title,
                .empty_description = words.empty_description,
                .show_kind = !domain.is_taxonomy and domain.fixed_kind == null,
                .manage_label = if (domain.is_taxonomy)
                    try session.translated("Terms", .{})
                else
                    try session.translated("Manage", .{}),
                .types = items.items,
                .total = @floatFromInt(listed.total),
                .range = pages.range,
                .previous_href = pages.previous_href,
                .next_href = pages.next_href,
            }, .{});
        }

        fn kind_label(session: *const Session, kind: Kind) Error![]const u8 {
            std.debug.assert(@typeInfo(Kind).@"enum".fields.len == 4);
            std.debug.assert(back.len > 0);

            return switch (kind) {
                .record => session.translated("Record type", .{}),
                .settings => session.translated("Settings", .{}),
                .component => session.translated("Component", .{}),
                .media => session.translated("Media", .{}),
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

            try render_form(&session, type_placement.new_def(&session, def), null, &.{});
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
            // A definition's own page: a taxonomy's terms, a type's fields.
            const back_href: ?[]const u8 = if (existing_handle) |handle|
                try print(arena, "{s}/{s}{s}", .{
                    back,
                    handle,
                    if (domain.is_taxonomy) "/terms" else "",
                })
            else
                null;
            const errors = try head_errors(arena, problems);
            const limits = model.content_type;
            const classified = !is_new and !domain.is_taxonomy and def.kind == .record;
            const choices: []const Choice = if (classified)
                choices_of(session, def) catch |err| return admin.fail(session, err, back)
            else
                &.{};
            const users: []const User = if (!is_new and domain.is_taxonomy)
                users_of(session, def) catch |err| return admin.fail(session, err, back)
            else
                &.{};

            const own_name: ?[]const u8 = if (back_href == null) null else def.name;
            const placement = try type_placement.props_of(session, def);
            const untranslated = try untranslated_of(session);
            const words = try domain.words(session);
            const parents = try parents_of(session, .{
                .label = words.title,
                .href = back,
            }, own_name, back_href);

            try admin.screen(session, .ok, views.TypeForm, .{
                .title = if (is_new) words.new_label else try session.translated("Settings", .{}),
                .parents = parents,
                .cancel_href = back_href orelse back,
                .noun = try session.declared(domain.noun),
                .action = action,
                .is_new = is_new,
                .choose_kind = domain.fixed_kind == null,
                .problems = try problem_items(arena, errors.rest),
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
                .internal = def.internal,
                .taxonomy_choices = choices,
                .taxonomies_action = if (classified)
                    try print(arena, "{s}/{s}/taxonomies", .{ back, def.handle })
                else
                    "",
                .used_by = users,
                .is_record = def.kind == .record,
                .is_settings = def.kind == .settings,
                .is_component = def.kind == .component,
                .base_url = try host_url_of(session),
                .visibility = if (def.public) "public" else "private",
                .is_public = def.public,
                .has_apps = placement.has_apps,
                .is_global = placement.is_global,
                .home = placement.home,
                .apps = placement.apps,
                .share_all = placement.share_all,
                .shares = placement.shares,
                .roles = placement.roles,
                .plural_name = def.plural_name,
                .noun_languages = try type_names.languages_of(
                    views.TypeForm.Noun_languagesItem,
                    arena,
                    def,
                ),
                .untranslated_label = try session.declared(untranslated.label),
                .keep_label = try session.declared(untranslated.keep),
                .keep_help = try session.declared(untranslated.keep_help),
                .omit_label = try session.declared(untranslated.omit),
                .omit_help = try session.declared(untranslated.omit_help),
                .falls_back = def.variant_fallback,
                .visual = model.editor.is_visual(def.editor),
                .rich_fields = try type_editor.choices(arena, def),
                .delete_action = delete_action,
                .workflow_type = if (!is_new and !domain.is_taxonomy and def.kind == .record)
                    def.handle
                else
                    "",
            }, .{});
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

            if (!domain.is_taxonomy) {
                def = try type_editor.with_body(session.arena, def);
            }

            const definition = model.content_type.encode(session.arena, def) catch {
                return error.OutOfMemory;
            };
            const created = registry.SDK.dispatch(&session.ctx, operations.Create, .{
                .definition = definition,
            }) catch |err| {
                return render_form(session, def, null, try problems_of(session, err, definition));
            };
            // A taxonomy goes on to its terms, a type to its fields.
            const location = try print(session.arena, "{s}/{s}{s}", .{
                back,
                created.handle,
                if (domain.is_taxonomy) "/terms" else "",
            });

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

        /// A type's taxonomies, as its settings tick them: the ticked ones its own, a
        /// registration left unticked taken off (hidden, its terms kept). A plugin's type
        /// takes this too; what its plugin declares stays.
        pub fn taxonomies(request: *Request, response: *Response, ctx: *Context) Error!void {
            std.debug.assert(request.method() == .post);
            std.debug.assert(!domain.is_taxonomy);

            var post = try admin.accept(request, response, ctx, back) orelse return;
            var session = &post.session;
            const form = &post.form;
            const handle = try admin.param(session, "handle", back) orelse return;
            const got = try load(session, handle) orelse return;
            const settings = try print(session.arena, "{s}/{s}/settings", .{ back, handle });
            const ticked = try values_of(session.arena, form, "taxonomy");
            const placed = on_type.of(&session.ctx, got.definition, .{
                .removed = true,
            }) catch |err| return admin.fail(session, err, settings);
            var kept: std.ArrayList(model.content_type.Classified) = .empty;

            for (got.definition.taxonomies) |classified| {
                if (classified.locked) {
                    try kept.append(session.arena, classified);
                }
            }

            for (ticked) |taxonomy| {
                if (!registered(placed, taxonomy) and !classified_in(kept.items, taxonomy)) {
                    try kept.append(session.arena, .{
                        .taxonomy = taxonomy,
                    });
                }
            }

            for (placed) |each| {
                if (each.placed.registered and !contains(ticked, each.placed.taxonomy)) {
                    try kept.append(session.arena, .{
                        .taxonomy = each.placed.taxonomy,
                        .removed = true,
                    });
                }
            }

            var def = got.definition;

            def.taxonomies = kept.items;

            const definition = model.content_type.encode(session.arena, def) catch {
                return error.OutOfMemory;
            };
            const in = keyed(operations.Update.In, domain.key, handle, .{
                .definition = definition,
            });

            _ = registry.SDK.dispatch(&session.ctx, operations.Update, in) catch |err| {
                return admin.fail(session, err, settings);
            };

            try response.redirect(.see_other, settings);
        }

        /// The head of the form over `base`: kind, names, handle (made from the name when
        /// empty), where it lives and who reads it. Fields and everything the form does not
        /// show stay as they are. A taxonomy has no kind and no URL; it is hierarchical or
        /// flat.
        fn head_of(arena: std.mem.Allocator, form: *const Form, base: Def) Error!Def {
            std.debug.assert(form.len <= admin.form_pairs_max);
            std.debug.assert(base.fields.len <= model.field.fields_max);

            var def = base;
            const name = form.text("name") orelse "";
            const has_url = form.get("has_url") != null;

            def = try type_names.read(arena, form, def);
            def.name = name;
            def.description = form.text("description") orelse "";
            def.handle = form.text("handle") orelse try handle_of(arena, name);

            if (domain.is_taxonomy) {
                def.kind = .record;
                def.url = "";
                def.hierarchical = form.get("hierarchical") != null;
                def.single = form.get("single") != null;
                def.internal = form.get("internal") != null;

                return type_placement.read(arena, form, def);
            }

            def.kind = domain.fixed_kind orelse
                (std.meta.stringToEnum(Kind, form.text("kind") orelse "") orelse base.kind);
            const routed = has_url and def.kind == .record;

            def.url = if (routed) form.text("url") orelse def.handle else "";
            def = try type_placement.read(arena, form, def);

            if (def.kind == .component) {
                def.public = false;
            }

            return type_editor.chosen(arena, form, def);
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
            const in = keyed(operations.Delete.In, domain.key, handle, .{
                .force = force,
            });

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
                    error.Conflict => (try domain.words(session)).conflict,
                    error.Denied => (try domain.words(session)).denied,
                    else => @errorName(err),
                };

                one[0] = .{
                    .path = "",
                    .message = message,
                };

                return one;
            }

            const checked = registry.SDK.dispatch(&session.ctx, operations.Validate, .{
                .definition = definition,
            }) catch return error.OutOfMemory;

            return checked.problems;
        }
    };
}

/// Every taxonomy a type may be filed under, the ones it is ticked: its own, a plugin's
/// registration unless taken off, its plugin's declared ones fixed.
fn choices_of(session: *Session, def: Def) ![]const Choice {
    std.debug.assert(session.signed_in());
    std.debug.assert(def.handle.len > 0);

    const placed = try on_type.of(&session.ctx, def, .{
        .removed = true,
    });
    const listed_all = try registry.SDK.dispatch(&session.ctx, taxonomy_operations.List, .{
        .limit = sdk_operation.page_limit_max,
    });
    var choices: std.ArrayList(Choice) = .empty;

    for (listed_all.taxonomies) |summary| {
        const found = for (placed) |each| {
            if (std.mem.eql(u8, each.placed.taxonomy, summary.handle)) {
                break each.placed;
            }
        } else null;

        const by = if (found) |each| each.by else "";

        try choices.append(session.arena, .{
            .value = summary.handle,
            .label = summary.name,
            .selected = if (found) |each| !each.removed else false,
            .locked = if (found) |each| each.locked else false,
            .note = if (by.len == 0)
                ""
            else
                try session.translated("Added by the {plugin} plugin", .{
                    .values = &.{.{
                        .name = "plugin",
                        .value = by,
                    }},
                }),
        });
    }

    return choices.items;
}

/// The types a taxonomy is on, and who put it on each.
fn users_of(session: *Session, def: Def) ![]const User {
    std.debug.assert(session.signed_in());
    std.debug.assert(def.handle.len > 0);

    const users = try on_type.used_by(&session.ctx, def.handle);
    const items = try session.arena.alloc(User, users.len);

    for (users, items) |used, *item| {
        const href = try print(session.arena, "/admin/types/{s}/settings", .{used.type});

        item.* = .{
            .id = href,
            .title = used.name,
            .type_label = try session.translated("Content type", .{}),
            .status = if (used.removed)
                try session.translated("Taken off", .{})
            else if (used.by.len == 0)
                try session.translated("Ticked by an administrator", .{})
            else
                try session.translated("Added by the {plugin} plugin", .{
                    .values = &.{.{
                        .name = "plugin",
                        .value = used.by,
                    }},
                }),
            .tone = if (used.removed) "neutral" else "success",
            .href = href,
        };
    }

    return items;
}

fn registered(placed: []const on_type.Found, handle: []const u8) bool {
    std.debug.assert(handle.len > 0);

    for (placed) |each| {
        if (each.placed.registered and std.mem.eql(u8, each.placed.taxonomy, handle)) {
            return true;
        }
    }

    return false;
}

fn classified_in(kept: []const model.content_type.Classified, handle: []const u8) bool {
    std.debug.assert(handle.len > 0);

    for (kept) |each| {
        if (std.mem.eql(u8, each.taxonomy, handle)) {
            return true;
        }
    }

    return false;
}

fn contains(values: []const []const u8, wanted: []const u8) bool {
    std.debug.assert(wanted.len > 0);

    for (values) |value| {
        if (std.mem.eql(u8, value, wanted)) {
            return true;
        }
    }

    return false;
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

/// Structure, the definitions' list, and, for an existing one, its own page.
fn parents_of(
    session: *const Session,
    list: views.TypeForm.ParentsItem,
    name: ?[]const u8,
    own_href: ?[]const u8,
) Error![]const views.TypeForm.ParentsItem {
    std.debug.assert(list.href.len > 0);
    std.debug.assert((name == null) == (own_href == null));

    const count: u32 = if (name == null) 2 else 3;
    const items = try session.arena.alloc(views.TypeForm.ParentsItem, count);

    items[0] = .{
        .label = try session.translated("Structure", .{}),
        .href = "/admin/structure",
    };
    items[1] = list;

    if (name) |own_name| {
        items[2] = .{
            .label = own_name,
            .href = own_href.?,
        };
    }

    return items;
}

fn problem_items(
    arena: std.mem.Allocator,
    problems: []const model.field.Problem,
) Error![]const views.TypeForm.ProblemsItem {
    std.debug.assert(problems.len <= model.field.problems_max);
    std.debug.assert(term_fields.len == 3);

    const items = try arena.alloc(views.TypeForm.ProblemsItem, problems.len);

    for (problems, 0..) |problem, index| {
        items[index] = .{
            .code = problem.path,
            .text = problem.message,
        };
    }

    return items;
}

/// Where the admin is, as the browser reached it: the scheme a proxy reports, else plain
/// http, and the host the request named.
pub fn host_url_of(session: *const Session) Error![]const u8 {
    std.debug.assert(session.signed_in());
    std.debug.assert(slug_field.len == 1);

    // On the admin's own host, the site's address is elsewhere.
    if (session.project.on_admin_host(session.request)) {
        return session.project.site_origin;
    }

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
        .{
            .path = "name",
            .message = "name must be 1 to 50 characters",
        },
        .{
            .path = "url",
            .message = "only a record type can be accessible via URL",
        },
        .{
            .path = "handle",
            .message = "handle must be [a-z][a-z0-9_]*, up to 64 characters",
        },
        .{
            .path = "name",
            .message = "second, kept in the list",
        },
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

    const In = struct {
        taxonomy: []const u8,
        definition: []const u8,
        drop_content: bool = false,
    };
    const in = keyed(In, "taxonomy", "topics", .{
        .definition = "{}",
    });
    try std.testing.expectEqualStrings("topics", in.taxonomy);
    try std.testing.expectEqualStrings("{}", in.definition);
    try std.testing.expect(!in.drop_content);
}

/// The untranslated-records setting's words, on a site with more than one variant whose
/// dimension names it; unnamed hides it.
fn untranslated_of(session: *Session) Error!Untranslated {
    std.debug.assert(session.signed_in());

    const words: ?Untranslated = comptime if (variants.setting()) |dimension|
        dimension.untranslated
    else
        null;
    const named = words orelse return .{};
    const others = variants.others(&session.ctx) catch return .{};

    return if (others.len == 0) .{} else named;
}

const Untranslated = @import("../../sdk/plugin/variants.zig").Untranslated;
