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
