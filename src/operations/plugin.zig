const std = @import("std");
const sdk = @import("../sdk.zig");
const model = @import("../model.zig");
const store = @import("../store.zig");
const trash = @import("trash.zig");
const state = @import("plugin/state.zig");
const lifecycle = @import("plugin/lifecycle.zig");
const versions = @import("plugin/versions.zig");
const dependents = @import("plugin/dependents.zig");
const views = @import("plugin/detail.zig");
const sources = @import("plugin/sources.zig");
const scaffold = @import("plugin/scaffold.zig");
const data = @import("plugin/data.zig");
const grants = @import("plugin/grants.zig");
const native = @import("plugin/native.zig");
const registry = @import("../server/registry.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace: sdk.operation.Namespace = .{
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

pub const Choice = grants.Choice;
pub const Request = state.Request;
pub const Summary = views.Summary;
pub const Detail = views.Detail;
pub const contracts = @import("plugin/contracts.zig");
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
    pub const In = struct {
        limit: u32 = 50,
        offset: u32 = 0,
    };
    pub const Out = struct {
        plugins: []const Summary,
        total: u32 = 0,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
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

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);

        if (in.limit == 0 or in.limit > sdk.operation.page_limit_max) {
            return error.Invalid;
        }

        const built_in = registry.native_plugins.all;
        var out: std.ArrayList(Summary) = .empty;

        inline for (built_in, 0..) |Plugin, index| {
            if (index >= in.offset and out.items.len < in.limit) {
                try out.append(ctx.arena, .{
                    .name = Plugin.manifest.name,
                    .version = Plugin.manifest.version,
                    .summary = Plugin.manifest.summary,
                    .mode = .native,
                    .enabled = true,
                    .pending = 0,
                    .update = null,
                });
            }
        }

        const room = in.limit - @as(u32, @intCast(out.items.len));

        if (room > 0) {
            const from = in.offset -| @as(u32, built_in.len);
            const rows = try store.sandboxed_plugins.page(ctx.db, ctx.arena, from, room);

            for (rows) |row| {
                const decoded = try state.decode(ctx.arena, row);

                try out.append(ctx.arena, try views.summary_of(ctx.arena, decoded));
            }
        }

        return .{
            .plugins = out.items,
            .total = @as(u32, built_in.len) + try store.sandboxed_plugins.count(ctx.db),
        };
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
    pub const example: In = .{
        .file = "farewell.wasm",
        .data = "AGFzbQ==",
        .last = false,
    };
    pub const example_out: Out = .{
        .file = "farewell.wasm",
        .received = 4,
    };
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
            return .{
                .file = in.file,
                .received = received,
            };
        }

        // Whether it is taken or refused, the upload is done with.
        defer sandboxed.consume(in.file);

        const added = try lifecycle.add(ctx, try lifecycle.stage(ctx, in.file, false));

        return .{
            .file = in.file,
            .received = received,
            .added = added,
        };
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
    pub const field_docs: sdk.operation.Docs(In) = .{
        .file = "The `.wasm` file's path",
    };
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
    pub const kind: sdk.operation.Kind = .write;
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
        .plugins = &.{views.example_enabled},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .names = "The plugins' names, what they depend on among them",
        .grants = "With one plugin: each request as `{ key, on, drafts, private, internal, " ++
            "publish, domains }`, a flag left out staying as asked",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .plugins = "Each plugin as it is after",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        try refuse_names(ctx, in.names);

        if (in.grants.len > grants.choices_max) {
            return ctx.refuse(&.{.{
                .field = "grants",
                .message = std.fmt.comptimePrint("At most {d} choices.", .{grants.choices_max}),
            }});
        }

        try dependents.refuse_missing_parents(ctx, in.names);

        if (in.grants.len > 0 and in.names.len != 1) {
            return error.Invalid;
        }

        const shown = ctx.arena.alloc(Detail, in.names.len) catch return error.OutOfMemory;

        for (in.names, shown) |plugin_name, *detail| {
            const enabled = try lifecycle.enable(ctx, plugin_name, in.grants);

            detail.* = try detail_of(ctx, enabled);
        }

        return .{
            .plugins = shown,
        };
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
) type {
    return struct {
        pub const name = operation_name;
        pub const description = text;
        pub const details = explained;
        pub const kind = operation_kind;
        pub const In = struct {
            name: []const u8,
        };
        pub const Out = Detail;
        pub const example: In = .{
            .name = "greeter",
        };
        pub const example_out: Out = documented;
        pub const field_docs: sdk.operation.Docs(In) = .{
            .name = "The plugin's name",
        };

        pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
            std.debug.assert(granted.allows());
            std.debug.assert(ctx.now_ms >= 0);

            const acted = try act(ctx, in.name);

            return detail_of(ctx, acted);
        }
    };
}

pub const Get = ByName(
    "plugin.get",
    "Read a plugin: every request and where it stands, its versions",
    "Each request (a permission, a hook, a raised limit, an added status) with the " ++
        "plugin's reason, its tier, and whether it is granted, pending, denied, or " ++
        "unavailable (nothing installed provides it); for a disabled plugin, as enabling " ++
        "it would leave it. With a " ++
        "next version waiting, its version and requests; with a previous one, its version.",
    .read,
    views.example_detail,
    native.load,
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
        .plugins = &.{views.example_disabled},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .names = "The plugins' names, dependents and what they depend on together",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .plugins = "Each plugin as it is after",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        try refuse_names(ctx, in.names);
        try dependents.refuse_left_behind(ctx, in.names, "disable");

        const shown = ctx.arena.alloc(Detail, in.names.len) catch return error.OutOfMemory;

        for (in.names, shown) |plugin_name, *detail| {
            const disabled = try lifecycle.disable(ctx, plugin_name);

            detail.* = try detail_of(ctx, disabled);
        }

        return .{
            .plugins = shown,
        };
    }
};

/// Refuses a list of plugins naming none, or more than are started or stopped together.
fn refuse_names(ctx: *Ctx, names: []const []const u8) error{Invalid}!void {
    if (names.len >= 1 and names.len <= dependents.together_max) {
        return;
    }

    return ctx.refuse(&.{.{
        .field = "names",
        .message = std.fmt.comptimePrint("Name 1 to {d} plugins.", .{dependents.together_max}),
    }});
}

pub const Update = ByName(
    "plugin.update",
    "Apply a plugin's next version, keeping the current one to roll back to",
    "Everything the next version asks for that something installed provides is granted: " ++
        "an administrator reviews it before. Not found when no next version waits.",
    .write,
    views.example_updated,
    versions.update,
);

pub const CancelUpdate = ByName(
    "plugin.cancel_update",
    "Drop a plugin's next version; the current one stays",
    "Not found when no next version waits.",
    .write,
    views.example_cancelled,
    versions.cancel_update,
);

pub const Rollback = ByName(
    "plugin.rollback",
    "Go back to the version the last update replaced",
    "The version it leaves becomes the previous one, so a roll back can be undone the " ++
        "same way. Not found when there is no previous version.",
    .write,
    views.example_rolled_back,
    versions.rollback,
);

/// Grant, revoke or deny one request: the same shape, a different change.
fn Decision(
    comptime operation_name: []const u8,
    comptime text: []const u8,
    comptime change: lifecycle.Change,
) type {
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
        pub const kind: sdk.operation.Kind = .write;
        pub const In = struct {
            name: []const u8,
            key: []const u8,
        };
        pub const Out = Detail;
        pub const example: In = .{
            .name = "greeter",
            .key = "users.names",
        };
        pub const example_out: Out = views.example_detail;
        pub const field_docs: sdk.operation.Docs(In) = .{
            .name = "The plugin's name",
            .key = "The request's key",
        };

        pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
            std.debug.assert(granted.allows());
            std.debug.assert(ctx.db.transaction_depth >= 1);

            const decided = try lifecycle.decide(ctx, in.name, in.key, change);

            return detail_of(ctx, decided);
        }
    };
}

pub const GrantRequest = Decision(
    "plugin.grant",
    "Grant one request a plugin makes",
    .grant,
);
pub const Revoke = Decision(
    "plugin.revoke",
    "Take back one thing granted to a plugin",
    .revoke,
);
pub const Deny = Decision(
    "plugin.deny",
    "Refuse one request a plugin makes",
    .deny,
);

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
    pub const kind: sdk.operation.Kind = .write;
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
    pub const example_out: Out = views.example_detail;
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The plugin's name",
        .key = "The request's key",
        .on = "Granted, or denied; left out, as it is",
        .drafts = "With `records.read` or `terms.read`: drafts, pending changes, history",
        .private = "With a read: content types marked Private",
        .internal = "With `records.read`: other plugins' internal records",
        .publish = "With `records.write` or `terms.write`: put things live",
        .domains = "With `http.fetch`: where it may send, replacing the list; at most 32",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        var decoded = try state.load(ctx, in.name);

        try grants.apply(ctx.arena, &decoded, .{
            .key = in.key,
            .on = in.on,
            .drafts = in.drafts,
            .private = in.private,
            .internal = in.internal,
            .publish = in.publish,
            .domains = in.domains,
        });
        try @import("plugin/statuses.zig").leave(ctx, in.name, &decoded);
        try state.save(ctx, decoded);

        return detail_of(ctx, decoded);
    }
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
    pub const kind: sdk.operation.Kind = .write;
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
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The plugin's name",
        .trash = "The keys of the pieces of its data that go to the trash; the rest stay",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        try dependents.refuse_left_behind(ctx, &.{in.name}, "remove");
        _ = try state.load(ctx, in.name);
        try data.put_in_trash(ctx, in.name, in.trash);

        const key = std.fmt.allocPrint(ctx.arena, "[\"{s}\"]", .{in.name}) catch {
            return error.OutOfMemory;
        };
        const own = [_]store.trash_copy.Root{.{
            .table = "sandboxed_plugins",
            .column = "name",
            .keys = key,
        }};
        const trash_id = try trash.keep(ctx, .{
            .kind = "plugin",
            .key = in.name,
            .label = std.fmt.allocPrint(ctx.arena, "Plugin {s}", .{in.name}) catch
                return error.OutOfMemory,
            .roots = &own,
        });

        try lifecycle.remove(ctx, in.name);

        return .{
            .removed = in.name,
            .trash = trash_id,
        };
    }
};

pub const operations = [_]type{
    List,         Get,          Upload, Add,  Enable,   Disable, Update, Rollback,
    CancelUpdate, GrantRequest, Revoke, Deny, SetGrant, Remove,  Data,   EraseData,
    LeftBehind,   RestoreData,
} ++ sources.operations ++ scaffold.operations ++ @import("plugin/market.zig").operations ++
    @import("plugin/log.zig").operations;

pub const Piece = data.Piece;
pub const Fate = data.Fate;

const example_pieces = [_]Piece{
    .{
        .key = "type:course",
        .kind = .type,
        .label = "Course",
        .count = 12,
    },
    .{
        .key = "internal:enrolments",
        .kind = .internal,
        .label = "enrolments",
        .count = 340,
        .trash = "0190a1b2c3d40001a1b2c3d4",
    },
};

pub const Data = struct {
    pub const name = "plugin.data";
    pub const description = "What data a plugin has: kept where it is, or in the trash";
    pub const details =
        \\Read from the database by owner, so an uninstalled plugin's data is listed too: the
        \\content types it owns (with their records), its taxonomies, the collections of
        \\internal records it keeps, its custom field groups and roles. Each a piece with a
        \\key; a piece in the trash names its entry (`trash`), which `trash restore` brings
        \\back. Uninstalling decides each piece (`plugin remove --trash`); `plugin
        \\erase_data` erases pieces for good.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        name: []const u8,
    };
    pub const Out = struct {
        pieces: []const Piece,
    };
    pub const example: In = .{
        .name = "greeter",
    };
    pub const example_out: Out = .{
        .pieces = &example_pieces,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The plugin's name",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (in.name.len == 0 or in.name.len > 64) {
            return error.Invalid;
        }

        return .{
            .pieces = try data.pieces_of(ctx, in.name),
        };
    }
};

const still_installed: sdk.operation.Failure = .{
    .name = "Installed",
    .status = 409,
    .message = "The plugin is still installed: uninstall it first, then erase its data",
};

pub const EraseData = struct {
    pub const name = "plugin.erase_data";
    pub const description = "Erase an uninstalled plugin's data for good";
    pub const details =
        \\Each piece named (keys from `plugin data`) is erased: one kept where it is is
        \\deleted with no copy, one in the trash has its entry removed. It cannot be undone.
        \\Only for a plugin that is not installed; a device (an agent) lists it for its
        \\person instead. The activity log keeps who erased which pieces, never the data.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const destroys = true;
    pub const In = struct {
        name: []const u8,
        pieces: []const []const u8,
    };
    pub const Out = struct {
        /// What went, in words: "Course (12 records), enrolments (340 internal records)".
        erased: []const u8,
    };
    pub const example: In = .{
        .name = "shelf",
        .pieces = &.{"type:shelf.item"},
    };
    pub const example_out: Out = .{
        .erased = "Item (1 record)",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The plugin's name",
        .pieces = "The keys of the pieces to erase",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.name.len == 0 or in.name.len > 64) {
            return error.Invalid;
        }

        const installed = try store.sandboxed_plugins.get(ctx.db, ctx.arena, in.name) != null;
        const built_in = try native.find(ctx, in.name) != null;

        if (installed or built_in) {
            return ctx.fail(still_installed);
        }

        return .{
            .erased = try data.erase(ctx, in.name, in.pieces),
        };
    }
};

pub const RestoreData = struct {
    pub const name = "plugin.restore_data";
    pub const description = "Bring pieces of a plugin's data back from the trash";
    pub const details =
        \\Each piece named (keys from `plugin data`, in the trash) comes back as it was. A
        \\content type or taxonomy the plugin made again since it was installed anew gives way
        \\when it is still empty; one holding anything stays, and that piece is refused.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
        pieces: []const []const u8,
    };
    pub const Out = struct {
        pieces: []const Piece,
    };
    pub const example: In = .{
        .name = "shelf",
        .pieces = &.{"type:shelf.item"},
    };
    pub const example_out: Out = .{
        .pieces = &example_pieces,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The plugin's name",
        .pieces = "The keys of the pieces to bring back",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.name.len == 0 or in.name.len > 64) {
            return error.Invalid;
        }

        try data.restore(ctx, in.name, in.pieces);

        return .{
            .pieces = try data.pieces_of(ctx, in.name),
        };
    }
};

/// One uninstalled plugin and what it left.
pub const Left = struct {
    name: []const u8,
    pieces: []const Piece,
    /// The plugin's own trash entry while it is there: `trash restore` reinstalls it.
    trash: []const u8 = "",
};

const example_left = [_]Left{.{
    .name = "greeter",
    .pieces = &example_pieces,
}};

pub const LeftBehind = struct {
    pub const name = "plugin.left_behind";
    pub const description = "Uninstalled plugins whose data is still here";
    pub const details =
        \\Each plugin that is not installed but whose data stays, kept where it is or in the
        \\trash, with its pieces as `plugin data` lists them, and its own trash entry while
        \\it is there. `plugin erase_data` purges pieces; `trash restore` brings them back.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        plugins: []const Left,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .plugins = &example_left,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{};

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        _ = in;

        var installed: std.ArrayList([]const u8) = .empty;

        for (try store.sandboxed_plugins.list(ctx.db, ctx.arena)) |row| {
            installed.append(ctx.arena, row.name) catch return error.OutOfMemory;
        }

        inline for (registry.native_plugins.all) |Plugin| {
            installed.append(ctx.arena, Plugin.manifest.name) catch return error.OutOfMemory;
        }

        const names = try data.left_behind(ctx, installed.items);
        const left = ctx.arena.alloc(Left, names.len) catch return error.OutOfMemory;

        for (names, left) |plugin, *item| {
            item.* = .{
                .name = plugin,
                .pieces = try data.pieces_of(ctx, plugin),
                .trash = try store.trash.id_of(ctx.db, ctx.arena, "plugin", plugin) orelse "",
            };
        }

        return .{
            .plugins = left,
        };
    }
};
