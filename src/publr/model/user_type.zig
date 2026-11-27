/// What a plugin declares in `.user_types`. Which apps the type's people may sign in to is a
/// setting on the type that administrators and agents change (`user_type.set`); `apps` is
/// where it starts.
pub const Declared = struct {
    /// `[a-z][a-z0-9_]*`, 1 to 32 characters, unique on the site: `customer`.
    name: []const u8,
    /// What people call one: "Customer".
    label: []const u8,
    /// The apps (`app.zon`'s `.name`) its people may sign in to until an administrator
    /// chooses; empty: none.
    apps: []const []const u8 = &.{},
    /// Anyone may make their own account of it on an app it opens (`user.sign_up`).
    sign_up: bool = false,
    /// The roles the type gives its people (on signing up, or `user.add_type`); one at least
    /// when `sign_up`. Member roles only: never `admin`, `editor` or `contributor`, nor a
    /// role whose grants reach past what members call (refused at enable and by the roles
    /// editor).
    roles: []const []const u8 = &.{},
    /// The app's page where its people set a password from the link they are sent, on
    /// signing up or asking for a new one: `/account/password?token=...`.
    password_page: []const u8 = "/account/password",
    /// The plugin that declares it; set by core.
    plugin: []const u8 = "",
};
