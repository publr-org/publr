/// What a type is for: `record` types hold any number of records (posts, hotels), a
/// `settings` type holds exactly one (the homepage, the header, general options), a
/// `component` holds none: it is a set of fields other types will reuse. A `media` type's
/// records are files: the library's own (`media`) or another set core or a plugin keeps
/// apart from it (pictures pasted into a chat). A media type shows only where its owner
/// draws it, never in Content.
pub const Kind = enum { record, settings, component, media };

const filter = @import("filter.zig");

/// How a type's list starts: the columns shown, the filters in force, its order.
pub const View = struct {
    columns: []const []const u8 = &.{},
    filters: []const filter.Clause = &.{},
    order: ?[]const u8 = null,
};

/// A definition (a content type, a taxonomy) as a list of them shows it.
pub const Summary = struct {
    id: []const u8,
    handle: []const u8,
    name: []const u8,
    kind: Kind,
    public: bool,
    system: bool,
    owner: []const u8,
    editor: []const u8,
    fields: u32,
    /// The app it lives in; empty for a Global type.
    app: []const u8 = "",
    /// The menu items its list sits under, the first that exists.
    menu_parents: []const []const u8 = &.{},
    /// `.menu = .none`: left out of the menu; its pages still open.
    menu_hidden: bool = false,
    /// Its default view: where its list starts.
    view: View = .{},
    /// An icon of the set; empty for none.
    icon: []const u8 = "",
};

/// A content type or a taxonomy as its definition holds it: what `content_type.get` and
/// `taxonomy.get` answer and `content_type.create` takes.
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
    /// Public: anyone reaching an app the type reaches reads its live records. Private:
    /// only callers that are signed in, whose roles allow it.
    public: bool = false,
    /// Private: the roles that reach it, administrators always; empty: every role whose
    /// grants reach records. A shop's orders are its administrators', not every editor's.
    roles: []const []const u8 = &.{},
    /// The app the type lives in (`app.zon`'s `.name`); empty for a Global type.
    app: []const u8 = "",
    /// The other apps that reach it; null for the default of where it lives.
    shared: ?Shared = null,
    /// Owned by Publr or a plugin: its declared fields are locked, only fields added by hand
    /// can change.
    system: bool = false,
    /// The plugin that declared it (its manifest name), empty for hand-made types.
    owner: []const u8 = "",
    editor: []const u8 = "form",
    editor_config: @import("editor.zig").Config = .{},
    title_field: []const u8 = "title",
    statuses: []const []const u8 = &.{},
    /// Its own statuses and the transitions between them; empty: Publr's flow.
    flow: @import("flow.zig").Flow = .{},
    /// A taxonomy whose terms may have a parent term; meaningless on a content type.
    hierarchical: bool = false,
    /// The taxonomies a content type is classified by, each an implicit `terms` field named
    /// after it; another plugin's registration adds more where it matches. Meaningless on a
    /// taxonomy, which never names types.
    taxonomies: []const Classified = &.{},
    /// A taxonomy whose records take one term, not several.
    single: bool = false,
    /// A taxonomy that never reaches the site: staff-only labels, order tags. Admin only; on
    /// a type only by its name, never by a pattern. Meaningless on a content type.
    internal: bool = false,
    group: @import("field_group.zig").Options = .{},
    menu: Menu = .{},
    view: View = .{},
    fields: []const @import("field.zig").Def,
};

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

/// One taxonomy on a content type's list: ticked by an administrator, declared by the type's
/// plugin (`locked`, there while the plugin declares it), or another plugin's registration
/// an administrator took off (`removed`: hidden, its assignments kept for when it comes back).
pub const Classified = struct {
    taxonomy: []const u8,
    locked: bool = false,
    removed: bool = false,
};

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
