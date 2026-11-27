//! Deciding a plugin's requests: one at a time (grant, revoke, deny), or a permission's
//! switch and flags (`set_grant`).
const operation = @import("../../operation.zig");
const detail = @import("detail.zig");

const Detail = detail.Detail;

/// One request as a person left it: the key on or off, and the flags it asked for, each on
/// or off (one not given stays as it is).
pub const Choice = struct {
    key: []const u8,
    on: ?bool = null,
    drafts: ?bool = null,
    private: ?bool = null,
    internal: ?bool = null,
    publish: ?bool = null,
    /// `http.fetch`'s domains as the person left them, replacing the list; null: as it is.
    domains: ?[]const []const u8 = null,
};

/// Grant, revoke or deny one request: the same shape, a different change.
pub fn Decision(comptime operation_name: []const u8, comptime text: []const u8) type {
    return struct {
        pub const name = operation_name;
        pub const description = text;
        pub const details =
            \\One request at a time, by its key as `plugin get` lists it: a permission
            \\(`records.write`), a hook (`after:record.save`), a raised limit
            \\(`limit.cpu_ms`) or an added status (`status:inventory.awaiting_stock`). It takes
            \\effect on the plugin's next call; a status's records leave by the plugin's own
            \\transition out of it before it is revoked or denied, refused if one may not.
        ;
        pub const kind: operation.Kind = .write;
        pub const In = struct {
            name: []const u8,
            key: []const u8,
        };
        pub const Out = Detail;
        pub const example: In = .{
            .name = "greeter",
            .key = "users.names",
        };
        pub const example_out: Out = detail.example_detail;
        pub const field_docs: operation.Docs(In) = .{
            .name = "The plugin's name",
            .key = "The request's key",
        };
    };
}

pub const GrantRequest = Decision("plugin.grant", "Grant one request a plugin makes");
pub const Revoke = Decision("plugin.revoke", "Take back one thing granted to a plugin");
pub const Deny = Decision("plugin.deny", "Refuse one request a plugin makes");

pub const SetGrant = struct {
    pub const name = "plugin.set_grant";
    pub const description = "Switch a plugin's permission, or one of its flags, on or off";
    pub const details =
        \\One request by its key, as `plugin get` lists it: `on` grants it (whatever its
        \\tier) or denies it, left out leaves it as it is; each flag it asked for (`drafts`,
        \\`private`, `internal`, `publish`) is switched on or off, one left out stays as it
        \\is. Never more than it asked for: a flag it did not ask for is invalid. `domains`
        \\replaces the list `http.fetch` may reach: each exact (`api.example.com`), a
        \\wildcard (`*.example.com`) or `*` (any public address). It takes effect on the
        \\plugin's next call; the code sees it in its answers (`.pending`, denied, nothing
        \\found, a request refused).
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
        key: []const u8,
        on: ?bool = null,
        drafts: ?bool = null,
        private: ?bool = null,
        internal: ?bool = null,
        publish: ?bool = null,
        domains: ?[]const []const u8 = null,
    };
    pub const Out = Detail;
    pub const example: In = .{
        .name = "greeter",
        .key = "users.names",
        .on = true,
    };
    pub const example_out: Out = detail.example_detail;
    pub const field_docs: operation.Docs(In) = .{
        .name = "The plugin's name",
        .key = "The request's key",
        .on = "Granted, or denied; left out, as it is",
        .drafts = "With `records.read` or `terms.read`: drafts, pending changes, history",
        .private = "With a read: content types marked Private",
        .internal = "With `records.read`: other plugins' internal records",
        .publish = "With `records.write` or `terms.write`: put things live",
        .domains = "With `http.fetch`: where it may send, replacing the list; at most 32",
    };
};
