//! Plugins, built in and installed: listing, adding, enabling and removing them here; their
//! versions, the decisions on their requests and the data they keep in the sub-files.
const operation = @import("../operation.zig");
const detail = @import("plugin/detail.zig");
const grants = @import("plugin/grants.zig");
const versions = @import("plugin/versions.zig");
const data = @import("plugin/data.zig");

pub const namespace: operation.Namespace = .{
    .name = "plugin",
    .label = "Plugins",
    .area = .system,
    .summary = "Installed plugins and apps: add, enable, grant, update, roll back, remove",
    .details =
    \\A plugin is a plugin (or an app) added at runtime from a `.wasm` file, without a
    \\build: it runs in a sandbox and can do only what its permissions allow. Added, it is
    \\listed and runs nothing; enabling grants what it asks for at the low and medium
    \\tiers, while high-tier permissions and raised limits wait for an administrator. Any
    \\grant can be revoked at any time, one at a time, and the plugin keeps running without
    \\it (its calls answer denied). A newer module for a plugin waits as its next version
    \\until it is applied; applying keeps the version it replaces, to roll back to.
    \\Administrators only.
    ,
};

pub const Mode = detail.Mode;
pub const Request = detail.Request;
pub const Summary = detail.Summary;
pub const Detail = detail.Detail;
pub const Choice = grants.Choice;
pub const Piece = data.Piece;
pub const Fate = data.Fate;
pub const Left = data.Left;
pub const Get = versions.Get;
pub const Update = versions.Update;
pub const CancelUpdate = versions.CancelUpdate;
pub const Rollback = versions.Rollback;
pub const GrantRequest = grants.GrantRequest;
pub const Revoke = grants.Revoke;
pub const Deny = grants.Deny;
pub const SetGrant = grants.SetGrant;
pub const Data = data.Data;
pub const EraseData = data.EraseData;
pub const RestoreData = data.RestoreData;
pub const LeftBehind = data.LeftBehind;
pub const Interfaces = @import("plugin/published.zig").Interfaces;
pub const Surface = @import("plugin/fit.zig").Surface;
pub const Fits = @import("plugin/fits.zig").Fits;
pub const Labels = @import("plugin/labels.zig").Labels;
pub const Log = @import("plugin/log.zig").Log;
pub const Scaffold = @import("plugin/scaffold.zig").Scaffold;
pub const Find = @import("plugin/market.zig").Find;
pub const Install = @import("plugin/market.zig").Install;

/// What adding a module did: a plugin new to the list, or a newer version of one there.
pub const Added = struct {
    name: []const u8,
    version: []const u8,
    update: bool,
};

pub const List = struct {
    pub const name = "plugin.list";
    pub const description = "List the plugins, built-in and installed";
    pub const details =
        \\Every plugin: the built-in ones (`mode` native: built into this binary, always
        \\enabled), then the installed ones (`mode` sandboxed), by name, each with its version,
        \\whether it runs, how many of its requests wait for an administrator, and the
        \\version of an update waiting, if any.
    ;
    pub const kind: operation.Kind = .read;
    pub const In = struct {
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        plugins: []const Summary,
        total: u32 = 0,
    };
    pub const field_docs: operation.Docs(In) = .{
        .limit = "How many at most; 50 when omitted, up to 200",
        .offset = "How many to pass over first: the built-in ones, then the installed by name",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .plugins = &.{.{
            .name = "greeter",
            .version = "0.1.0",
            .summary = "Greetings kept as records",
            .mode = .sandboxed,
            .enabled = true,
            .pending = 0,
            .update = "0.2.0",
        }},
    };
};

pub const Upload = struct {
    pub const name = "plugin.upload";
    pub const description = "Add a plugin from a module sent a piece at a time";
    pub const details =
        \\What the admin's Upload button does: the module arrives in pieces small enough for one
        \\request each, base64 in `data`. The first piece (`offset` 0) starts it afresh; each
        \\next one must start where the last ended, or it conflicts. The last piece (`last`)
        \\adds it as `plugin add` does: a new plugin, disabled, or the next version of
        \\one already there. Names are letters, digits, dots, dashes and underscores, ending
        \\in `.wasm`; up to 16 MiB in all.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        file: []const u8,
        offset: u64 = 0,
        data: []const u8,
        last: bool = true,
    };
    pub const Out = struct {
        file: []const u8,
        received: u64,
        /// Once the last piece is in: the plugin it added or updated.
        added: ?Added = null,
    };
    pub const example: In = .{
        .file = "farewell.wasm",
        .data = "AGFzbQ==",
        .last = false,
    };
    pub const example_out: Out = .{
        .file = "farewell.wasm",
        .received = 4,
    };
    pub const field_docs: operation.Docs(In) = .{
        .file = "The module's file name",
        .offset = "Where this piece starts: 0, then the bytes received so far",
        .data = "The piece, base64",
        .last = "Whether this is the last piece",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .file = "The module's file name",
        .received = "How many bytes arrived so far",
        .added = "With the last piece: the plugin, its version, and whether it is an update",
    };
};

pub const Add = struct {
    pub const name = "plugin.add";
    pub const description = "Add a plugin from a module on this machine; nothing runs yet";
    pub const details =
        \\For the local operator only (`--as-admin`): `file` is any path this machine reads. A
        \\new plugin is added, disabled; a module for a plugin already there becomes its
        \\next version, applied with `plugin update`. Refused when the module does not load
        \\in the sandbox, when its name is core's or a built-in plugin's, or when its
        \\operations or roles reach outside its own namespace.
    ;
    pub const operator_only = true;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        file: []const u8,
    };
    pub const Out = Added;
    pub const example: In = .{
        .file = "greeter-0.2.0.wasm",
    };
    pub const example_out: Out = .{
        .name = "greeter",
        .version = "0.2.0",
        .update = true,
    };
    pub const field_docs: operation.Docs(In) = .{
        .file = "The `.wasm` file's path",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .name = "The plugin's name",
        .version = "The module's version",
        .update = "Whether it is the next version of a plugin already there",
    };
};

pub const Enable = struct {
    pub const name = "plugin.enable";
    pub const description = "Start plugins: low and medium granted, high pending";
    pub const details =
        \\One or several at once, all or none. Refused while a plugin one depends on is not
        \\running and not among them: the refusal names it and the command that starts them
        \\together. Refused too when a content type one declares belongs to someone else.
        \\Their content types are created; each is granted what it asks for at the low and
        \\medium tiers (what it held before, if disabled, stays). `grants` then sets what a
        \\person chose on the review: each key on (granted, whatever its tier) or off
        \\(denied), each flag it asked for on or off, and `http.fetch`'s `domains` as the
        \\person left them. Invalid for a flag not asked for.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        names: []const []const u8,
        grants: []const Choice = &.{},
    };
    pub const Out = struct {
        plugins: []const Detail,
    };
    pub const example: In = .{
        .names = &.{"farewell"},
    };
    pub const example_out: Out = .{
        .plugins = &.{detail.example_enabled},
    };
    pub const field_docs: operation.Docs(In) = .{
        .names = "The plugins' names, what they depend on among them",
        .grants = "With one plugin: each request as `{ key, on, drafts, private, internal, " ++
            "publish, domains }`, a flag left out staying as asked",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .plugins = "Each plugin as it is after",
    };
    /// What one plugin's enabling takes beside its manifest: its types made, its page's
    /// detail.
    pub const enable_bytes: u32 = 1 << 19;
    /// How many times its manifest's length reading it takes: the text, and what it parses
    /// into.
    pub const manifest_factor: u32 = 4;
};

pub const Disable = struct {
    pub const name = "plugin.disable";
    pub const description = "Stop plugins: operations and hooks unload, grants and content stay";
    pub const details =
        \\One or several at once, all or none. Refused while an enabled plugin left running
        \\names one of them in `depends_on`: the refusal names it and the command that stops
        \\them together. A plugin that only lists one in `compatible_with` keeps running, its
        \\hooks into it silent. Enabling a plugin again brings it back with what it held.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        names: []const []const u8,
    };
    pub const Out = struct {
        plugins: []const Detail,
    };
    pub const example: In = .{
        .names = &.{"greeter"},
    };
    pub const example_out: Out = .{
        .plugins = &.{detail.example_disabled},
    };
    pub const field_docs: operation.Docs(In) = .{
        .names = "The plugins' names, dependents and what they depend on together",
    };
    pub const output_docs: operation.Docs(Out) = .{
        .plugins = "Each plugin as it is after",
    };
};

pub const Remove = struct {
    pub const name = "plugin.remove";
    pub const description = "Uninstall a plugin: off the list, into the trash";
    pub const details =
        \\Its operations and hooks stop at once; it waits in the trash with its grants and
        \\versions, and `trash restore` brings it back as it was. Its data stays where it is,
        \\except the pieces named in `trash` (keys from `plugin data`): each goes into the
        \\trash as an entry of its own, restorable on its own. Erasing data for good is
        \\`plugin erase_data`, once the plugin is uninstalled. Refused, like `plugin
        \\disable`, while an enabled plugin depends on it.
    ;
    pub const kind: operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
        trash: []const []const u8 = &.{},
    };
    pub const Out = struct {
        removed: []const u8,
        /// Its trash entry: `trash restore --id` brings it back.
        trash: []const u8 = "",
    };
    pub const example: In = .{
        .name = "greeter",
    };
    pub const example_out: Out = .{
        .removed = "greeter",
        .trash = "0190a1b2c3d40001a1b2c3d4",
    };
    pub const field_docs: operation.Docs(In) = .{
        .name = "The plugin's name",
        .trash = "The keys of the pieces of its data that go to the trash; the rest stay",
    };
};
