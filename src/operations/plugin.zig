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
const scaffold = @import("plugin/scaffold.zig");
const data = @import("plugin/data.zig");
const grants = @import("plugin/grants.zig");
const native = @import("plugin/native.zig");
const registry = @import("../server/registry.zig");
const public = @import("../publr/operations/plugin.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const namespace = public.namespace;

pub const Choice = grants.Choice;
pub const Request = state.Request;
pub const Summary = views.Summary;
pub const Detail = views.Detail;
pub const contracts = @import("plugin/contracts.zig");
pub const Interfaces = @import("plugin/published.zig").Interfaces;
pub const Surface = @import("plugin/fit.zig").Surface;
pub const Fits = @import("plugin/fits.zig").Fits;
pub const Added = lifecycle.Added;
pub const Labels = @import("plugin/labels.zig").Labels;

const detail_of = views.detail_of;

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const field_docs = shape.field_docs;
    pub const example = shape.example;
    pub const example_out = shape.example_out;

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
    pub const shape = public.Upload;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
    pub const shape = public.Add;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const operator_only = shape.operator_only;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
    pub const shape = public.Enable;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;
    pub const enable_bytes = shape.enable_bytes;
    pub const manifest_factor = shape.manifest_factor;

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
        const order = try started_order(ctx, in.names);
        var there: std.ArrayList(contracts.Provider) = .empty;

        there.appendSlice(ctx.arena, try contracts.providers(ctx, .{})) catch {
            return error.OutOfMemory;
        };

        // Several plugins: each worked on in memory of its own, given back once it is
        // enabled; only what it answers and what it provides stay, so enabling many takes
        // the largest. One is worked on in the request's arena.
        const kept = ctx.arena;
        const several = order.len > 1;
        var working: std.heap.FixedBufferAllocator = .init(if (several)
            try kept.alloc(u8, try enable_bytes_of(ctx, order))
        else
            &.{});

        _ = try ctx.scratch();
        defer ctx.arena = kept;

        for (order, shown) |plugin_name, *detail| {
            working.reset();
            ctx.arena = if (several) working.allocator() else kept;

            const enabled = try lifecycle.enable_among(ctx, plugin_name, in.grants, there.items);
            const enabled_detail = try views.detail_among(ctx, enabled, there.items);

            try contracts.append(kept, ctx.arena, &there, &enabled.manifest);
            detail.* = try model.deep_copy.copy(Detail, kept, enabled_detail);
        }

        return .{
            .plugins = shown,
        };
    }

    /// The most the largest of `order` takes to enable, from its manifest's length.
    fn enable_bytes_of(ctx: *Ctx, order: []const []const u8) Error!u32 {
        std.debug.assert(order.len > 1);
        std.debug.assert(manifest_factor > 1);

        var largest: u32 = 0;

        for (order) |plugin_name| {
            const bytes = try store.sandboxed_plugins.manifest_bytes(ctx.db, plugin_name);

            largest = @max(largest, bytes);
        }

        return enable_bytes + largest * manifest_factor;
    }
};

/// An operation on one plugin by its name, answering the plugin as it is after.
fn ByName(
    comptime Shape: type,
    comptime act: fn (*Ctx, []const u8) Error!state.Decoded,
) type {
    return struct {
        pub const shape = Shape;
        pub const name = shape.name;
        pub const description = shape.description;
        pub const details = shape.details;
        pub const kind = shape.kind;
        pub const In = shape.In;
        pub const Out = shape.Out;
        pub const example = shape.example;
        pub const example_out = shape.example_out;
        pub const field_docs = shape.field_docs;

        pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
            std.debug.assert(granted.allows());
            std.debug.assert(ctx.now_ms >= 0);

            const acted = try act(ctx, in.name);

            return detail_of(ctx, acted);
        }
    };
}

pub const Get = ByName(public.Get, native.load);

pub const Disable = struct {
    pub const shape = public.Disable;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
/// `names` in the order they start: each after the plugins among them it depends on.
fn started_order(ctx: *Ctx, names: []const []const u8) Error![]const []const u8 {
    std.debug.assert(names.len <= dependents.together_max);

    const enable_order = @import("plugin/enable_order.zig");
    const named = ctx.arena.alloc(enable_order.Named, names.len) catch return error.OutOfMemory;

    const installed = try store.sandboxed_plugins.needs(ctx.db, ctx.arena);

    for (names, named) |plugin_name, *one| {
        const row = for (installed) |each| {
            if (std.mem.eql(u8, each.name, plugin_name)) break each;
        } else return error.NotFound;

        one.* = .{
            .name = plugin_name,
            .depends_on = std.json.parseFromSliceLeaky(
                []const []const u8,
                ctx.arena,
                row.depends_on,
                .{},
            ) catch return error.Invalid,
        };
    }

    return enable_order.ordered(ctx.arena, named) catch error.OutOfMemory;
}

test {
    _ = @import("plugin/enable_order.zig");
}

fn refuse_names(ctx: *Ctx, names: []const []const u8) error{Invalid}!void {
    if (names.len >= 1 and names.len <= dependents.together_max) {
        return;
    }

    return ctx.refuse(&.{.{
        .field = "names",
        .message = std.fmt.comptimePrint("Name 1 to {d} plugins.", .{dependents.together_max}),
    }});
}

pub const Update = ByName(public.Update, versions.update);

pub const CancelUpdate = ByName(public.CancelUpdate, versions.cancel_update);

pub const Rollback = ByName(public.Rollback, versions.rollback);

/// Grant, revoke or deny one request: the same shape, a different change.
fn Decision(comptime Shape: type, comptime change: lifecycle.Change) type {
    return struct {
        pub const shape = Shape;
        pub const name = shape.name;
        pub const description = shape.description;
        pub const details = shape.details;
        pub const kind = shape.kind;
        pub const In = shape.In;
        pub const Out = shape.Out;
        pub const example = shape.example;
        pub const example_out = shape.example_out;
        pub const field_docs = shape.field_docs;

        pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
            std.debug.assert(granted.allows());
            std.debug.assert(ctx.db.transaction_depth >= 1);

            const decided = try lifecycle.decide(ctx, in.name, in.key, change);

            return detail_of(ctx, decided);
        }
    };
}

pub const GrantRequest = Decision(public.GrantRequest, .grant);
pub const Revoke = Decision(public.Revoke, .revoke);
pub const Deny = Decision(public.Deny, .deny);

pub const SetGrant = struct {
    pub const shape = public.SetGrant;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
    pub const shape = public.Remove;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
    List,         Get,          Upload,     Add,    Enable,   Disable, Update, Rollback,
    CancelUpdate, GrantRequest, Revoke,     Deny,   SetGrant, Remove,  Data,   EraseData,
    LeftBehind,   RestoreData,  Interfaces, Labels, Surface,  Fits,
} ++ scaffold.operations ++ @import("plugin/market.zig").operations ++
    @import("plugin/log.zig").operations;

pub const Piece = data.Piece;
pub const Fate = data.Fate;

pub const Data = struct {
    pub const shape = public.Data;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
    pub const shape = public.EraseData;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const destroys = shape.destroys;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
    pub const shape = public.RestoreData;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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

pub const Left = public.Left;

pub const LeftBehind = struct {
    pub const shape = public.LeftBehind;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

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
