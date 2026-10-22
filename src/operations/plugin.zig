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
    pub const description = "Remove a plugin: off the list, into the trash";
    pub const details =
        \\Its operations and hooks stop at once; it waits in the trash with its grants and
        \\versions, and `trash restore` brings it back as it was. Its data stays, except the
        \\pieces chosen with `plugin choose_removal`: those go into the same trash entry.
        \\Refused, like `plugin disable`, while an enabled plugin depends on it.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
    };
    pub const Out = struct {
        removed: []const u8,
        /// Its trash entry: `trash restore --id` brings it back.
        trash: []const u8 = "",
        /// The content types chosen to go with it, by handle.
        types_removed: []const []const u8 = &.{},
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
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        try dependents.refuse_left_behind(ctx, &.{in.name}, "remove");

        const decoded = try state.load(ctx, in.name);
        const going = try data.going(ctx, decoded);
        const key = std.fmt.allocPrint(ctx.arena, "[\"{s}\"]", .{in.name}) catch {
            return error.OutOfMemory;
        };
        var roots: std.ArrayList(store.trash_copy.Root) = .empty;

        const own: store.trash_copy.Root = .{
            .table = "sandboxed_plugins",
            .column = "name",
            .keys = key,
        };

        roots.append(ctx.arena, own) catch return error.OutOfMemory;
        roots.appendSlice(ctx.arena, try data.roots_of(ctx, in.name, going)) catch
            return error.OutOfMemory;

        const label = if (going.len == 0)
            std.fmt.allocPrint(ctx.arena, "Plugin {s}", .{in.name})
        else
            std.fmt.allocPrint(ctx.arena, "Plugin {s}, with {s}", .{
                in.name,
                try data.summary_of(ctx, going),
            });
        const trash_id = try trash.keep(ctx, .{
            .kind = "plugin",
            .key = in.name,
            .label = label catch return error.OutOfMemory,
            .roots = roots.items,
        });

        const types_removed: []const []const u8 = if (going.len > 0)
            try data.drop(ctx, in.name, going)
        else
            &.{};

        try lifecycle.remove(ctx, in.name);

        return .{
            .removed = in.name,
            .trash = trash_id,
            .types_removed = types_removed,
        };
    }
};

pub const operations = [_]type{
    List,         Get,          Upload, Add,  Enable,   Disable, Update, Rollback,
    CancelUpdate, GrantRequest, Revoke, Deny, SetGrant, Remove,  Data,   ChooseRemoval,
} ++ sources.operations ++ scaffold.operations ++ @import("plugin/market.zig").operations ++
    @import("plugin/log.zig").operations;

pub const Piece = data.Piece;

const example_pieces = [_]Piece{
    .{
        .key = "type:course",
        .kind = .type,
        .label = "Course",
        .count = 12,
        .chosen = true,
    },
    .{
        .key = "internal:enrolments",
        .kind = .internal,
        .label = "enrolments",
        .count = 340,
        .chosen = false,
    },
};

pub const Data = struct {
    pub const name = "plugin.data";
    pub const description = "What data a plugin manages, and which of it goes when it is removed";
    pub const details =
        \\Read from the database: the content types it owns (with their records), the
        \\collections of internal records it keeps, the custom field groups it declared. Each
        \\a piece with a key; `chosen` ones go into the trash with the plugin when it is
        \\removed (`plugin choose_removal`), the rest stay. None is chosen until an
        \\administrator chooses.
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
        std.debug.assert(in.name.len <= 64 << 10);

        const decoded = try native.load(ctx, in.name);

        return .{
            .pieces = try data.pieces_of(ctx, decoded),
        };
    }
};

pub const ChooseRemoval = struct {
    pub const name = "plugin.choose_removal";
    pub const description = "Choose which of a plugin's data goes with it when it is removed";
    pub const details =
        \\`remove` holds the keys of the pieces `plugin data` lists that go into the trash
        \\with the plugin; an empty list keeps everything, which is how every plugin starts.
        \\Disabling never touches data, and neither does removing what is not chosen.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        name: []const u8,
        remove: []const []const u8 = &.{},
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
        .remove = "The keys of the pieces to remove with it",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        const decoded = try state.load(ctx, in.name);

        try data.choose(ctx, decoded, in.remove);

        return .{
            .pieces = try data.pieces_of(ctx, decoded),
        };
    }
};
