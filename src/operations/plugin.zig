const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const state = @import("plugin/state.zig");
const lifecycle = @import("plugin/lifecycle.zig");
const versions = @import("plugin/versions.zig");
const dependents = @import("plugin/dependents.zig");
const views = @import("plugin/detail.zig");
const registry = @import("../server/registry.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace: sdk.operation.Namespace = .{
    .name = "plugin",
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

pub const ContentAccess = state.ContentAccess;
pub const Request = state.Request;
pub const Summary = views.Summary;
pub const Detail = views.Detail;
pub const Added = lifecycle.Added;

const detail_of = views.detail_of;

pub const List = struct {
    pub const name = "plugin.list";
    pub const description = "List the plugins, built-in and installed";
    pub const details =
        \\Every plugin: the built-in ones (`mode` native: built into this binary, always
        \\enabled), then the installed ones (`mode` sandboxed), by name, each with its version,
        \\whether it runs, how many of its requests wait for an administrator, and the
        \\version of an update waiting, if any.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct { plugins: []const Summary };
    pub const example: In = .{};
    pub const example_out: Out = .{ .plugins = &.{.{
        .name = "greeter",
        .version = "0.1.0",
        .summary = "Greetings kept as records",
        .mode = .sandboxed,
        .enabled = true,
        .pending = 0,
        .update = "0.2.0",
    }} };

    pub fn run(ctx: *Ctx, _: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const built_in = registry.native_plugins.all;
        const rows = try store.sandboxed_plugins.list(ctx.db, ctx.arena);
        const out = try ctx.arena.alloc(Summary, built_in.len + rows.len);

        inline for (built_in, 0..) |Plugin, index| {
            out[index] = .{
                .name = Plugin.manifest.name,
                .version = Plugin.manifest.version,
                .summary = Plugin.manifest.summary,
                .mode = .native,
                .enabled = true,
                .pending = 0,
                .update = null,
            };
        }

        for (rows, out[built_in.len..]) |row, *summary| {
            summary.* = try views.summary_of(ctx.arena, try state.decode(ctx.arena, row));
        }

        return .{ .plugins = out };
    }
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
    pub const kind: sdk.operation.Kind = .write;
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
    pub const example: In = .{ .file = "farewell.wasm", .data = "AGFzbQ==", .last = false };
    pub const example_out: Out = .{ .file = "farewell.wasm", .received = 4 };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .file = "The module's file name",
        .offset = "Where this piece starts: 0, then the bytes received so far",
        .data = "The piece, base64",
        .last = "Whether this is the last piece",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .file = "The module's file name",
        .received = "How many bytes arrived so far",
        .added = "With the last piece: the plugin, its version, and whether it is an update",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(in.data) catch return error.Invalid;

        if (in.file.len > 128 or size > model.sandboxed_plugin.bytes_max) {
            return error.Invalid;
        }

        const bytes = try ctx.arena.alloc(u8, size);

        decoder.decode(bytes, in.data) catch return error.Invalid;

        const sandboxed = try lifecycle.sandboxed(ctx);
        const received = try sandboxed.receive(in.file, in.offset, bytes, in.last);

        if (!in.last) {
            return .{ .file = in.file, .received = received };
        }

        // Whether it is taken or refused, the upload is done with.
        defer sandboxed.consume(in.file);

        const added = try lifecycle.add(ctx, try lifecycle.stage(ctx, in.file, false));

        return .{ .file = in.file, .received = received, .added = added };
    }
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
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { file: []const u8 };
    pub const Out = Added;
    pub const example: In = .{ .file = "greeter-0.2.0.wasm" };
    pub const example_out: Out = .{ .name = "greeter", .version = "0.2.0", .update = true };
    pub const field_docs: sdk.operation.Docs(In) = .{ .file = "The `.wasm` file's path" };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .name = "The plugin's name",
        .version = "The module's version",
        .update = "Whether it is the next version of a plugin already there",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (ctx.caller != .system) {
            return error.Denied;
        }

        return lifecycle.add(ctx, try lifecycle.stage(ctx, in.file, true));
    }
};

pub const Enable = struct {
    pub const name = "plugin.enable";
    pub const description = "Start a plugin: low and medium granted, high pending";
    pub const details =
        \\Refused while a plugin it depends on is missing, or when a content type it declares
        \\belongs to someone else. Its content types are created; it is granted what it asks
        \\for at the low and medium tiers (what it held before, if disabled, stays).
        \\`content_access` is `public` (the default), `all`, or `specific` with `types`.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
        content_access: state.Scope = .public,
        types: []const []const u8 = &.{},
    };
    pub const Out = Detail;
    pub const example: In = .{ .name = "farewell" };
    pub const example_out: Out = views.example_enabled;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The plugin's name",
        .content_access = "`public`, `all` or `specific`",
        .types = "With `specific`: the content types, by handle",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.types.len > 64) {
            return error.Invalid;
        }

        const access: ContentAccess = .{ .scope = in.content_access, .types = in.types };

        const enabled = try lifecycle.enable(ctx, in.name, access);

        ctx.notice("plugin.enabled", in.name);

        return detail_of(ctx, enabled);
    }
};

/// An operation on one plugin by its name, answering the plugin as it is after.
fn ByName(
    comptime operation_name: []const u8,
    comptime text: []const u8,
    comptime explained: []const u8,
    comptime operation_kind: sdk.operation.Kind,
    comptime documented: Detail,
    comptime act: fn (*Ctx, []const u8) Error!state.Decoded,
    /// What it raises when it changed the plugin; null for a read.
    comptime notice: ?[]const u8,
) type {
    return struct {
        pub const name = operation_name;
        pub const description = text;
        pub const details = explained;
        pub const kind = operation_kind;
        pub const In = struct { name: []const u8 };
        pub const Out = Detail;
        pub const example: In = .{ .name = "greeter" };
        pub const example_out: Out = documented;
        pub const field_docs: sdk.operation.Docs(In) = .{ .name = "The plugin's name" };

        pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
            std.debug.assert(granted.allows());
            std.debug.assert(ctx.now_ms >= 0);

            const acted = try act(ctx, in.name);

            if (notice) |notice_name| {
                ctx.notice(notice_name, in.name);
            }

            return detail_of(ctx, acted);
        }
    };
}

pub const Get = ByName(
    "plugin.get",
    "Read a plugin: every request and where it stands, its versions",
    "Each request (a permission, a hook, a raised limit) with the plugin's reason, its " ++
        "tier, and whether it is granted, pending, denied, or unavailable (nothing installed " ++
        "provides it); for a disabled plugin, as enabling it would leave it. With a " ++
        "next version waiting, its version and requests; with a previous one, its version.",
    .read,
    views.example_detail,
    state.load,
    null,
);

pub const Disable = struct {
    pub const name = "plugin.disable";
    pub const description = "Stop plugins: operations and hooks unload, grants and content stay";
    pub const details =
        \\One or several at once, all or none. Refused while an enabled plugin left running
        \\names one of them in `depends_on`: the refusal names it and the command that stops
        \\them together. A plugin that only lists one in `compatible_with` keeps running, its
        \\hooks into it silent. Enabling a plugin again brings it back with what it held.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { names: []const []const u8 };
    pub const Out = struct { plugins: []const Detail };
    pub const rules: sdk.operation.Rules(In) = .{
        .names = .{ .items_min = 1, .items_max = dependents.together_max },
    };
    pub const example: In = .{ .names = &.{"greeter"} };
    pub const example_out: Out = .{ .plugins = &.{views.example_disabled} };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .names = "The plugins' names, dependents and what they depend on together",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .plugins = "Each plugin as it is after",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        try dependents.refuse_left_behind(ctx, in.names, "disable");

        const shown = ctx.arena.alloc(Detail, in.names.len) catch return error.OutOfMemory;

        for (in.names, shown) |plugin_name, *detail| {
            const disabled = try lifecycle.disable(ctx, plugin_name);

            ctx.notice("plugin.disabled", plugin_name);
            detail.* = try detail_of(ctx, disabled);
        }

        return .{ .plugins = shown };
    }
};

pub const Update = ByName(
    "plugin.update",
    "Apply a plugin's next version, keeping the current one to roll back to",
    "Everything the next version asks for that something installed provides is granted: " ++
        "an administrator reviews it before. Not found when no next version waits.",
    .write,
    views.example_updated,
    versions.update,
    "plugin.updated",
);

pub const CancelUpdate = ByName(
    "plugin.cancel_update",
    "Drop a plugin's next version; the current one stays",
    "Not found when no next version waits.",
    .write,
    views.example_cancelled,
    versions.cancel_update,
    "plugin.update_cancelled",
);

pub const Rollback = ByName(
    "plugin.rollback",
    "Go back to the version the last update replaced",
    "The version it leaves becomes the previous one, so a roll back can be undone the " ++
        "same way. Not found when there is no previous version.",
    .write,
    views.example_rolled_back,
    versions.rollback,
    "plugin.rolled_back",
);

/// Grant, revoke or deny one request: the same shape, a different change.
fn Decision(
    comptime operation_name: []const u8,
    comptime text: []const u8,
    comptime change: lifecycle.Change,
    comptime notice: []const u8,
) type {
    return struct {
        pub const name = operation_name;
        pub const description = text;
        pub const details =
            \\One request at a time, by its key as `plugin get` lists it: a permission
            \\(`content.write`), a hook (`after:record.save`) or a raised limit
            \\(`limit.cpu_ms`). It takes effect on the plugin's next call.
        ;
        pub const kind: sdk.operation.Kind = .write;
        pub const In = struct { name: []const u8, key: []const u8 };
        pub const Out = Detail;
        pub const example: In = .{ .name = "greeter", .key = "users.names" };
        pub const example_out: Out = views.example_detail;
        pub const field_docs: sdk.operation.Docs(In) = .{
            .name = "The plugin's name",
            .key = "The request's key",
        };

        pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
            std.debug.assert(granted.allows());
            std.debug.assert(ctx.db.transaction_depth >= 1);

            const decided = try lifecycle.decide(ctx, in.name, in.key, change);

            ctx.notice(notice, in.name);

            return detail_of(ctx, decided);
        }
    };
}

pub const GrantRequest = Decision(
    "plugin.grant",
    "Grant one request a plugin makes",
    .grant,
    "plugin.granted",
);
pub const Revoke = Decision(
    "plugin.revoke",
    "Take back one thing granted to a plugin",
    .revoke,
    "plugin.revoked",
);
pub const Deny = Decision(
    "plugin.deny",
    "Refuse one request a plugin makes",
    .deny,
    "plugin.denied",
);

pub const SetContentAccess = struct {
    pub const name = "plugin.set_content_access";
    pub const description = "Choose which content types a plugin's content permissions reach";
    pub const details =
        \\`public` (every public type), `all` (every type, public and private, including
        \\ones added later) or `specific` with `types`. Its own types it always reaches.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
        scope: state.Scope,
        types: []const []const u8 = &.{},
    };
    pub const Out = Detail;
    pub const example: In = .{ .name = "greeter", .scope = .specific, .types = &.{"post"} };
    pub const example_out: Out = specific: {
        var chosen = views.example_detail;

        chosen.content_access = .{ .scope = .specific, .types = &.{"post"} };

        break :specific chosen;
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The plugin's name",
        .scope = "`public`, `all` or `specific`",
        .types = "With `specific`: the content types, by handle",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.types.len > 64) {
            return error.Invalid;
        }

        var decoded = try state.load(ctx, in.name);

        decoded.content_access = .{ .scope = in.scope, .types = in.types };
        try state.save(ctx, decoded);
        ctx.notice("plugin.content_access_set", in.name);

        return detail_of(ctx, decoded);
    }
};

pub const Remove = struct {
    pub const name = "plugin.remove";
    pub const description = "Remove a plugin: off the list, its grants and versions dropped";
    pub const details =
        \\Its operations and hooks stop at once. Its content types and their records stay
        \\until an administrator deletes them. Refused, like `plugin disable`, while an
        \\enabled plugin depends on it.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct { name: []const u8 };
    pub const Out = struct { removed: []const u8 };
    pub const example: In = .{ .name = "greeter" };
    pub const example_out: Out = .{ .removed = "greeter" };
    pub const field_docs: sdk.operation.Docs(In) = .{ .name = "The plugin's name" };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        try dependents.refuse_left_behind(ctx, &.{in.name}, "remove");
        try lifecycle.remove(ctx, in.name);
        ctx.notice("plugin.removed", in.name);

        return .{ .removed = in.name };
    }
};

pub const operations = [_]type{
    List,         Get,          Upload, Add,  Enable,           Disable, Update, Rollback,
    CancelUpdate, GrantRequest, Revoke, Deny, SetContentAccess, Remove,
};
