//! A content type as data: its definition (handle, names, fields), how it is checked, and
//! how it is written to and read from JSON. No database.

const std = @import("std");
const ids = @import("../lib/id.zig");
pub const field = @import("field.zig");
const kinds = @import("kinds.zig");
pub const flow = @import("flow.zig");

pub const handle_len_max: u32 = 64;
pub const name_len_max: u32 = 50;
pub const description_len_max: u32 = 500;
pub const url_len_max: u32 = 128;
pub const definition_bytes_max: u32 = 1 << 20;
pub const id_len = ids.len;
pub const statuses_max: u32 = 64;
/// The apps a type may be shared with by name, besides every app at once.
pub const shared_apps_max: u32 = 64;
/// The owner of the types core declares itself (media, templates, the moodboard): the
/// project's own, in every app's reach, as a type without an owner is.
pub const core_owner = "publr";

/// What a type is for: `record` types hold any number of records (posts, hotels), a
/// `settings` type holds exactly one (the homepage, the header, general options), a
/// `component` holds none: it is a set of fields other types will reuse. A `media` type's
/// records are files: the library's own (`media`) or another set core or a plugin keeps
/// apart from it (pictures pasted into a chat). A media type shows only where its owner
/// draws it, never in Content.
pub const Kind = enum { record, settings, component, media };

/// The apps that reach a type besides the one it lives in: every app (apps added later
/// too), or the ones listed. A Global type is shared with every app unless it says
/// otherwise; an app's type with none.
pub const Shared = struct {
    all: bool = false,
    apps: []const []const u8 = &.{},
};

/// Where a type's list sits in the admin's menu: under the first of these menu items that
/// exists (`checkout.orders`), else where content types go.
pub const Menu = struct {
    parents: []const []const u8 = &.{},
    /// `.menu = .none`: no entry in the menu; its pages still open at their addresses.
    hidden: bool = false,
};

/// A type's default view of its list, as its plugin gives it: the columns shown after the
/// title, and where the list starts (filters people can clear, an order: `-number`). What
/// a list can filter and order by is the fields' to say (`filterable`, `sortable`).
pub const View = struct {
    columns: []const []const u8 = &.{},
    filters: []const @import("filter.zig").Clause = &.{},
    order: ?[]const u8 = null,
};

pub const menu_parents_max: u32 = 8;
pub const view_columns_max: u32 = @import("view.zig").columns_max;

/// A type's name in one of the admin's languages, as the sentences that decline it need it:
/// its gender and its forms, singular and plural, by case (`genitive`), as the language's
/// pack names them. A form left out reads the name.
pub const NounForms = struct {
    locale: []const u8,
    gender: []const u8 = "",
    forms: []const NounForm = &.{},
};

pub const NounForm = struct {
    case: []const u8,
    singular: []const u8 = "",
    plural: []const u8 = "",
};

pub const Def = struct {
    handle: []const u8,
    name: []const u8,
    /// The name for more than one: `Products`; empty reads the name.
    plural_name: []const u8 = "",
    /// The name declined in the admin's other languages.
    noun_forms: []const NounForms = &.{},
    /// What the type is for, in a sentence or two, for the people who build with it.
    description: []const u8 = "",
    kind: Kind = .record,
    /// The file families a media type takes (`image`, `pdf`...); empty takes every one the
    /// library takes. Meaningless on other kinds.
    families: []const []const u8 = &.{},
    icon: []const u8 = "",
    /// Where its records live on the site, `posts` for `/posts/<slug>`; empty for a type
    /// without pages of its own. Public and Private types alike may have one.
    url: []const u8 = "",
    /// Public: any visitor of an app the type reaches reads its live records. Private:
    /// only callers that are signed in, whose roles allow it.
    public: bool = false,
    /// Private: the roles that reach it, administrators always; empty: every role whose
    /// grants reach records. A shop's orders are its administrators', not every editor's.
    roles: []const []const u8 = &.{},
    /// The app the type lives in (`app.zon`'s `.name`); empty for a Global type.
    app: []const u8 = "",
    /// The other apps that reach it; null for the default of where it lives.
    shared: ?Shared = null,
    /// Owned by the core or a plugin: its declared fields are locked, only fields added
    /// by hand can change.
    system: bool = false,
    /// The plugin that declared it (its manifest name), empty for hand-made types.
    owner: []const u8 = "",
    editor: []const u8 = "form",
    editor_config: []const u8 = "{}",
    title_field: []const u8 = "title",
    statuses: []const []const u8 = &.{},
    /// Its own statuses and the transitions between them; empty: core's flow.
    flow: flow.Flow = .{},
    /// A taxonomy whose terms may have a parent term; meaningless on a content type.
    hierarchical: bool = false,
    /// The content types a taxonomy classifies, by handle: each gets an implicit `terms`
    /// field named after the taxonomy. Meaningless on a content type.
    applies_to: []const []const u8 = &.{},
    /// A taxonomy whose records take one term, not several.
    single: bool = false,
    /// A record not written in a variant (a language) still shows there, in its main values;
    /// false leaves it out of that variant: not listed, its address there not found.
    variant_fallback: bool = true,
    group: @import("field_group.zig").Options = .{},
    menu: Menu = .{},
    view: View = .{},
    fields: []const field.Def,
};

/// A type's handle: a name, `[a-z][a-z0-9_]*`, or a plugin's type under the plugin's name
/// (`products.variant`).
pub fn valid_handle(handle: []const u8) bool {
    std.debug.assert(handle_len_max > 0);

    if (handle.len == 0 or handle.len > handle_len_max) {
        return false;
    }

    const dot = std.mem.indexOfScalar(u8, handle, '.') orelse return field.valid_name(handle);

    return field.valid_name(handle[0..dot]) and field.valid_name(handle[dot + 1 ..]);
}

/// What a type's own statuses are named under: the plugin that declares it
/// (`products.variant` -> `products`), else the type itself.
pub fn namespace_of(handle: []const u8) []const u8 {
    std.debug.assert(handle.len > 0);

    const dot = std.mem.indexOfScalar(u8, handle, '.') orelse return handle;

    std.debug.assert(dot > 0);

    return handle[0..dot];
}

test "a handle is a name, or a plugin's name and the type's" {
    try std.testing.expect(valid_handle("post"));
    try std.testing.expect(valid_handle("products.variant"));
    try std.testing.expect(!valid_handle("products."));
    try std.testing.expect(!valid_handle("a.b.c"));
    try std.testing.expect(!valid_handle("Post"));
    try std.testing.expectEqualStrings("products", namespace_of("products.variant"));
    try std.testing.expectEqualStrings("post", namespace_of("post"));
}

pub fn validate_def(known: []const kinds.Kind, def: Def, problems: *field.Problems) void {
    std.debug.assert(problems.len <= field.problems_max);
    std.debug.assert(handle_len_max > 0);

    if (!@import("field_group.zig").valid(def.group)) {
        problems.add("group", "invalid field group location rules");
    }

    if (def.fields.len > field.fields_max) {
        problems.add("fields", field.too_many_fields);
        return;
    }

    if (def.title_field.len > field.name_len_max) {
        problems.add("title_field", "title_field must be up to 64 characters");
        return;
    }

    if (!valid_handle(def.handle)) {
        problems.add("handle", "handle must be [a-z][a-z0-9_]*, a plugin's under its name " ++
            "(`products.variant`), up to 64 characters");
    }

    if (def.name.len == 0 or def.name.len > name_len_max) {
        problems.add("name", "name must be 1 to 50 characters");
    }

    if (def.description.len > description_len_max) {
        problems.add("description", "description must be up to 500 characters");
    }

    @import("editor.zig").validate(def.editor, def.editor_config, def.fields, problems);

    if (def.statuses.len > statuses_max) {
        problems.add("statuses", "too many statuses");
    }

    validate_flow(def, problems);

    if (!valid_url(def.url)) {
        problems.add("url", "url must be path segments of [a-z0-9_-], up to 128 characters");
    }

    validate_placement(def, problems);

    if (def.url.len > 0 and def.kind != .record) {
        problems.add("url", "only a record type can be accessible via URL");
    }

    validate_families(def, problems);

    if (def.url.len > 0 and !has_slug(def.fields)) {
        problems.add("url", "a type accessible via URL needs a slug field: each record's " ++
            "page is its address followed by the slug");
    }

    field.validate_defs(known, def.fields, 0, problems);

    if (title_field_of(def)) |title| {
        if (!kinds.lookup(known, title.kind).title_allowed) {
            problems.add("title_field", "title_field must be a field whose kind allows titles");
        }
    }
}

fn validate_placement(def: Def, problems: *field.Problems) void {
    std.debug.assert(problems.len <= field.problems_max);
    std.debug.assert(shared_apps_max > 0);

    const app_name = @import("app.zig").valid_name;

    if (def.app.len > 0 and !app_name(def.app)) {
        problems.add("app", "app must be an app's name, [a-z][a-z0-9_]*");
    }

    const role_model = @import("role.zig");

    if (def.roles.len > role_model.roles_max) {
        problems.add("roles", "at most 64 roles");
    } else for (def.roles) |name| {
        if (!role_model.valid_name(name)) {
            problems.add("roles", "roles by their names, [a-z][a-z0-9_]*");
            break;
        }
    }

    const shared = def.shared orelse return;

    if (shared.apps.len > shared_apps_max) {
        problems.add("shared", "shared with at most 64 apps by name");
        return;
    }

    for (shared.apps, 0..) |name, index| {
        if (!app_name(name)) {
            problems.add("shared", "shared with apps by their names, [a-z][a-z0-9_]*");
            return;
        }

        for (shared.apps[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier, name)) {
                problems.add("shared", "an app is named twice");
                return;
            }
        }
    }
}

/// Who the type is shared with: what it says, else every app for a Global type and none
/// for an app's.
pub fn shared_of(def: Def) Shared {
    std.debug.assert(def.app.len <= 64);

    if (def.shared) |shared| {
        return shared;
    }

    return .{
        .all = def.app.len == 0,
    };
}

/// Whether the app named reaches a type living in `home` and shared as `shared`: its own
/// app always, another when shared with it.
pub fn reaches(home: []const u8, shared: Shared, app: []const u8) bool {
    std.debug.assert(app.len > 0);
    std.debug.assert(shared.apps.len <= shared_apps_max);

    if (std.mem.eql(u8, home, app) or shared.all) {
        return true;
    }

    for (shared.apps) |listed| {
        if (std.mem.eql(u8, listed, app)) {
            return true;
        }
    }

    return false;
}

pub fn reached_by(def: Def, app: []const u8) bool {
    std.debug.assert(app.len > 0);

    return reaches(def.app, shared_of(def), app);
}

pub fn has_slug(fields: []const field.Def) bool {
    std.debug.assert(fields.len <= field.fields_max);

    for (fields) |candidate| {
        if (field.is_slug(candidate.kind)) {
            return true;
        }
    }

    std.debug.assert(fields.len <= field.fields_max);

    return false;
}

fn has_title(fields: []const field.Def) bool {
    std.debug.assert(fields.len <= field.fields_max);

    for (fields) |candidate| {
        if (std.mem.eql(u8, candidate.name, "title")) {
            return std.mem.eql(u8, candidate.kind, "string");
        }
    }

    return false;
}

/// Empty, or path segments of lowercase letters, digits, `_` and `-`, joined by `/`.
pub fn valid_url(url: []const u8) bool {
    std.debug.assert(url_len_max > 0);

    if (url.len > url_len_max) {
        return false;
    }

    var previous: u8 = '/';

    for (url) |char| {
        const lower = char >= 'a' and char <= 'z';
        const digit = char >= '0' and char <= '9';
        const mark = char == '_' or char == '-';

        if (char == '/' and previous == '/') {
            return false;
        }

        if (!(lower or digit or mark or char == '/')) {
            return false;
        }

        previous = char;
    }

    std.debug.assert(url.len <= url_len_max);

    return url.len == 0 or (url[0] != '/' and url[url.len - 1] != '/');
}

/// The field records take their title from: the top-level field `title_field` names,
/// when the type has one. A type built up field by field has none until it does.
pub fn title_field_of(def: Def) ?*const field.Def {
    std.debug.assert(def.fields.len <= field.fields_max);
    std.debug.assert(def.title_field.len <= field.name_len_max or def.fields.len == 0);

    if (def.title_field.len == 0) {
        return null;
    }

    return find_field(def.fields, def.title_field);
}

pub fn find_field(fields: []const field.Def, name: []const u8) ?*const field.Def {
    std.debug.assert(fields.len <= field.fields_max);

    for (fields) |*candidate| {
        if (std.mem.eql(u8, candidate.name, name)) {
            return candidate;
        }
    }

    return null;
}

/// Everything here fails like the database does, plus `Invalid` for a definition that is
/// not the JSON we expect.
pub const Error = error{ Invalid, OutOfMemory };

fn validate_families(def: Def, problems: *field.Problems) void {
    std.debug.assert(field.options.media_types_max > 0);

    if (def.families.len > 0 and def.kind != .media) {
        problems.add("families", "only a media type takes file families");
        return;
    }

    if (def.kind == .media and !has_title(def.fields)) {
        problems.add("fields", "a media type has a `title` field: a file is titled after " ++
            "its name");
    }

    if (def.families.len > field.options.media_types_max) {
        problems.add("families", "too many file families");
        return;
    }

    for (def.families) |family| {
        if (!field.options.valid_media_type(family)) {
            problems.add("families", "families must name the library's file families");
            return;
        }
    }
}

pub fn encode(arena: std.mem.Allocator, def: Def) Error![]const u8 {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(def.fields.len <= field.fields_max);

    return std.json.Stringify.valueAlloc(arena, def, .{}) catch error.OutOfMemory;
}

pub fn decode(arena: std.mem.Allocator, text: []const u8) Error!Def {
    std.debug.assert(definition_bytes_max > field.name_len_max);

    if (text.len == 0 or text.len > definition_bytes_max) {
        return error.Invalid;
    }

    const options: std.json.ParseOptions = .{
        .allocate = .alloc_always,
    };

    var def = @import("../lib/json.zig").parse(Def, arena, text, options) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
    };
    def.fields = try @import("field/presets.zig").apply(arena, def.fields);
    return def;
}

/// A type's id is derived from its handle, so the same declared type gets the same id
/// in every database (copies of a project, parity harnesses); a renamed type keeps its id.
pub const id_of = ids.derived;

pub const test_post: Def = .{
    .handle = "post",
    .name = "Post",
    .public = true,
    .fields = &.{
        .{
            .name = "title",
            .label = "Title",
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
                .source = "title",
            },
        },
        .{
            .name = "body",
            .label = "Body",
            .kind = "richtext",
            .searchable = true,
        },
        .{
            .name = "views",
            .label = "Views",
            .kind = "integer",
        },
        .{
            .name = "tags",
            .label = "Tags",
            .kind = "reference",
            .many = true,
            .options = .{
                .to = &.{"tag"},
            },
        },
    },
};

/// A type's own statuses are named under it and every transition and its start name a status the
/// type has: what makes the flow one Publr can follow.
fn validate_flow(def: Def, problems: *field.Problems) void {
    std.debug.assert(def.handle.len > 0);
    std.debug.assert(def.flow.transitions.len <= flow.transitions_max);

    if (def.flow.statuses.len > statuses_max) {
        problems.add("flow", "too many statuses");
    }

    const namespace = namespace_of(def.handle);

    for (def.flow.statuses) |own| {
        const named = own.id.len > namespace.len + 1 and
            std.mem.startsWith(u8, own.id, namespace) and own.id[namespace.len] == '.';

        if (!named or own.label.len == 0) {
            problems.add("flow", "a type's own status is named under its plugin " ++
                "(`guestbook.in_review`), or its type when no plugin declares it, and labelled");
        }
    }

    if (def.flow.start.len > 0 and def.flow.find(def.flow.start) == null) {
        problems.add("flow", "it starts in a status it does not have");
    }

    for (def.flow.transitions) |transition| {
        const target = def.flow.find(transition.to) != null;
        var known = transition.name.len > 0 and transition.from.len > 0 and target;

        for (transition.from) |leaving| {
            known = known and def.flow.find(leaving) != null;
        }

        if (!known) {
            problems.add("flow", "a transition is named and goes between statuses the type has");
        }
    }
}

test "definition validation" {
    var problems: field.Problems = .{};
    validate_def(&kinds.core, test_post, &problems);
    try std.testing.expect(problems.is_empty());

    var bad: field.Problems = .{};
    const wrong: Def = .{
        .handle = "Post",
        .name = "",
        .description = "x" ** 501,
        .title_field = "body",
        .fields = &.{.{
            .name = "body",
            .label = "Body",
            .kind = "text",
        }},
    };
    validate_def(&kinds.core, wrong, &bad);
    try std.testing.expectEqual(@as(u32, 4), bad.len);
}

test "an email field may title a record, a long text field may not" {
    var problems: field.Problems = .{};
    const signup: Def = .{
        .handle = "signup",
        .name = "Signup",
        .title_field = "email",
        .fields = &.{.{
            .validation = .{
                .unique = true,
            },
            .name = "email",
            .label = "Email",
            .kind = "email",
        }},
    };
    validate_def(&kinds.core, signup, &problems);
    try std.testing.expect(problems.is_empty());

    var refused: field.Problems = .{};
    var untitled = signup;
    untitled.title_field = "note";
    untitled.fields = &.{.{
        .name = "note",
        .label = "Note",
        .kind = "text",
    }};
    validate_def(&kinds.core, untitled, &refused);
    try std.testing.expectEqual(@as(u32, 1), refused.len);
    try std.testing.expectEqualStrings("title_field", refused.items[0].path);
}

test "a type may start empty, and its title field is whichever field the name finds" {
    var problems: field.Problems = .{};
    const empty: Def = .{
        .handle = "homepage",
        .name = "Homepage",
        .fields = &.{},
    };
    validate_def(&kinds.core, empty, &problems);
    try std.testing.expect(problems.is_empty());
    try std.testing.expect(title_field_of(empty) == null);
    try std.testing.expectEqual(Kind.record, empty.kind);

    const titled: Def = .{
        .handle = "hotel",
        .name = "Hotel",
        .kind = .settings,
        .title_field = "name",
        .fields = &.{.{
            .name = "name",
            .label = "Name",
            .kind = "string",
        }},
    };
    try std.testing.expectEqualStrings("name", title_field_of(titled).?.name);

    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const encoded = try encode(arena_state.allocator(), titled);
    const decoded = try decode(arena_state.allocator(), encoded);
    try std.testing.expectEqual(Kind.settings, decoded.kind);
    try std.testing.expectEqualStrings("string", decoded.fields[0].kind);

    try std.testing.expect(valid_url(""));
    try std.testing.expect(valid_url("posts"));
    try std.testing.expect(valid_url("blog/posts"));
    try std.testing.expect(!valid_url("/posts"));
    try std.testing.expect(!valid_url("posts//x"));
    try std.testing.expect(!valid_url("Posts"));

    var url_problems: field.Problems = .{};
    var unlisted = empty;
    unlisted.url = "pages";
    validate_def(&kinds.core, unlisted, &url_problems);
    // No slug field; a Private type may have pages (gated content).
    try std.testing.expectEqual(@as(u32, 1), url_problems.len);

    var sluggable: field.Problems = .{};
    var listed = titled;
    listed.kind = .record;
    listed.url = "hotels";
    listed.public = true;
    listed.fields = &.{.{
        .name = "slug",
        .label = "Slug",
        .kind = "slug",
    }};
    listed.title_field = "";
    validate_def(&kinds.core, listed, &sluggable);
    try std.testing.expect(sluggable.is_empty());

    var settings_problems: field.Problems = .{};
    listed.kind = .settings;
    validate_def(&kinds.core, listed, &settings_problems);
    try std.testing.expectEqual(@as(u32, 1), settings_problems.len);
}

test "a type reaches its own app, and the apps it is shared with" {
    const global: Def = .{
        .handle = "country",
        .name = "Country",
        .fields = &.{},
    };
    try std.testing.expect(reached_by(global, "www"));
    try std.testing.expect(reached_by(global, "shop"));

    var stock = global;
    stock.app = "warehouse";
    try std.testing.expect(reached_by(stock, "warehouse"));
    try std.testing.expect(!reached_by(stock, "www"));

    stock.shared = .{
        .apps = &.{"www"},
    };
    try std.testing.expect(reached_by(stock, "www"));
    try std.testing.expect(!reached_by(stock, "portal"));

    var listed = global;
    listed.shared = .{
        .apps = &.{"www"},
    };
    try std.testing.expect(reached_by(listed, "www"));
    try std.testing.expect(!reached_by(listed, "shop"));

    var problems: field.Problems = .{};
    var wrong = stock;
    wrong.app = "Warehouse";
    wrong.shared = .{
        .apps = &.{ "www", "www" },
    };
    validate_def(&kinds.core, wrong, &problems);
    try std.testing.expectEqual(@as(u32, 2), problems.len);
}

test "malformed definitions are rejected before internal field assumptions" {
    const cases = [_]Def{
        .{
            .handle = "post",
            .name = "Post",
            .fields = &([_]field.Def{test_post.fields[0]} ** (field.fields_max + 1)),
        },
        .{
            .handle = "post",
            .name = "Post",
            .fields = test_post.fields,
            .title_field = "x" ** 65,
        },
        .{
            .handle = "post",
            .name = "Post",
            .fields = &.{
                .{
                    .name = "x" ** 65,
                    .label = "X",
                    .kind = "string",
                },
            },
        },
        .{
            .handle = "post",
            .name = "Post",
            .fields = &.{
                .{
                    .name = "x",
                    .label = "X",
                    .kind = "x" ** (kinds.string_len_max + 1),
                },
            },
        },
        .{
            .handle = "post",
            .name = "Post",
            .fields = &.{
                .{
                    .name = "x",
                    .label = "X",
                    .kind = "number",
                    .options = .{
                        .choices = &([_][]const u8{"1"} ** (field.choices_max + 1)),
                    },
                },
            },
        },
        .{
            .handle = "post",
            .name = "Post",
            .fields = &.{
                .{
                    .validation = .{
                        .min = std.math.nan(f64),
                    },
                    .name = "x",
                    .label = "X",
                    .kind = "number",
                },
            },
        },
    };

    for (cases) |def| {
        var problems: field.Problems = .{};
        validate_def(&kinds.core, def, &problems);
        try std.testing.expect(!problems.is_empty());
    }
}
