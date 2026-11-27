//! The pages a person pins to the admin's rail: `rail.list`, `rail.pin`, `rail.unpin`.
const operation = @import("../operation.zig");

pub const namespace: operation.Namespace = .{
    .name = "rail",
    .label = "Rail pins",
    .area = .background,
    .summary = "The pages a person pins to their rail",
    .details =
    \\The rail holds Overview, Content and Media, then what the person pinned, in the order
    \\pinned. Nothing else adds to it: a plugin registers pages and sections, and people pin
    \\the ones they use. A pin names a page: a core one by its address below `/admin/`
    \\(`settings/users`, `trash`, `settings/<handle>` for a settings section), or a plugin's
    \\by the plugin and its page (a page's path, a settings page's address, or
    \\`section/<name>` for a section, named by its menu item: `products`, `section/shop`).
    \\Each person pins for themselves; administrators may also pin for everyone
    \\(`for_everyone`): those come first on every rail, and a person may hide one for
    \\themselves by unpinning it. A page someone may not see is not drawn. Signed-in
    \\callers only.
    ,
};

/// A page on the rail: a core one (`plugin` empty) or a plugin's.
pub const Pinned = struct {
    plugin: []const u8,
    page: []const u8,
    /// Pinned by an administrator for everyone.
    shared: bool = false,
};

pub const List = struct {
    pub const name = "rail.list";
    pub const description = "List the pages on the caller's rail, top to bottom";
    pub const details =
        \\The pins made for everyone (`shared`), less those the caller hid, then the
        \\caller's own. A pin whose page is gone (its plugin removed) stays listed and is
        \\not drawn; unpin it to drop it.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        pins: []const Pinned,
    };
    pub const example: In = .{};
    // A new account has pinned nothing; `rail pin` answers each pin as it lands.
    pub const example_out: Out = .{
        .pins = &.{},
    };
};

pub const Pin = struct {
    pub const name = "rail.pin";
    pub const description = "Pin a page to the caller's rail, below the others";
    pub const details =
        \\`page` alone for a core page; `plugin` and `page` for a plugin's. Invalid unless the
        \\page exists. Pinned already, it stays where it is. Up to 16 pins. `for_everyone`
        \\pins it to everyone's rail (administrators only), up to 16.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        plugin: []const u8 = "",
        page: []const u8,
        for_everyone: bool = false,
    };
    pub const Out = Pinned;
    pub const example: In = .{
        .page = "settings/users",
    };
    pub const example_out: Out = .{
        .plugin = "",
        .page = "settings/users",
    };
    pub const field_docs: operation.Docs(In) = .{
        .plugin = "The plugin whose page it is; empty for a core page",
        .page = "The page: `settings/users`, a plugin page's path, `section/<menu item>`",
        .for_everyone = "On everyone's rail (administrators only)",
    };
};

pub const Unpin = struct {
    pub const name = "rail.unpin";
    pub const description = "Take a page off the caller's rail, or off everyone's";
    pub const details =
        \\The page itself stays where it is listed. Not pinned, nothing changes. A pin made
        \\for everyone is hidden from the caller's rail alone; `for_everyone` takes it off
        \\every rail (administrators only).
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        plugin: []const u8 = "",
        page: []const u8,
        for_everyone: bool = false,
    };
    pub const Out = Pinned;
    pub const example: In = .{
        .page = "settings/users",
    };
    pub const example_out: Out = .{
        .plugin = "",
        .page = "settings/users",
    };
    pub const field_docs: operation.Docs(In) = .{
        .plugin = "The plugin whose page it is; empty for a core page",
        .page = "The page, as pinned",
        .for_everyone = "Off everyone's rail (administrators only)",
    };
};
