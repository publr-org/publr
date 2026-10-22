//! What core's writes change, as units read from each one's input and answer. Core's readers
//! (the activity log, a plugin recording deployments) hook these operations `after`, the way
//! any plugin hooks an operation, and hear each unit; nothing is raised under a second name.
//! A move over many records names each one in its typed transition event (`Moves`).
const std = @import("std");
const sdk = @import("../sdk.zig");
const content_types = @import("../operations/content_type.zig");
const taxonomies = @import("../operations/taxonomy.zig");
const custom_fields = @import("../operations/custom_fields.zig");
const plugins = @import("../operations/plugin.zig");
const plugin_sources = @import("../operations/plugin/sources.zig");
const views = @import("../operations/view.zig");
const view_defaults = @import("../operations/view_default.zig");
const snapshots = @import("../operations/snapshot.zig");
const trash = @import("../operations/trash.zig");
const users = @import("../operations/user.zig");
const user_manage = @import("../operations/user/manage.zig");
const identity = @import("../operations/identity.zig");
const identity_manage = @import("../operations/identity/manage.zig");
const project_put = @import("../operations/project/put.zig");
const records = @import("../operations/record.zig");
const terms = @import("../operations/term.zig");
const moves = @import("changed_units/moves.zig");

pub const Moves = moves.Moves;
pub const moved = moves.moved;

const Ctx = sdk.Ctx;
const Error = sdk.Error;

pub const Kind = enum {
    record,
    term,
    content_type,
    taxonomy,
    field_group,
    plugin,
    view,
    user,
    internal,
};

/// One thing a write changed: a type's or taxonomy's handle, a field group's, a plugin's
/// name, a view's id (a type's default view by the type's handle), anything else's id.
pub const Unit = struct {
    kind: Kind,
    key: []const u8,

    /// `plugin:shelf`.
    pub fn text(unit: Unit, arena: std.mem.Allocator) Error![]const u8 {
        std.debug.assert(unit.key.len > 0);

        const written = std.fmt.allocPrint(arena, "{t}:{s}", .{ unit.kind, unit.key }) catch {
            return error.OutOfMemory;
        };

        std.debug.assert(written.len > unit.key.len);

        return written;
    }
};

/// What a reader does with a unit a write changed, inside that write.
pub const Keep = fn (ctx: *Ctx, operation: []const u8, unit: Unit) void;

pub const Units = std.ArrayList(Unit);

/// One `after` hook for each write that may change a unit of `kinds`: it hands `keep` each
/// of those the write changed, in its order.
pub fn hooks(comptime kinds: []const Kind, comptime keep: Keep) [hooked(bits_of(kinds))]type {
    comptime {
        const wanted = bits_of(kinds);
        var list: [hooked(wanted)]type = undefined;
        var count: u32 = 0;

        for (writes) |Write| {
            if (Write.bits & wanted != 0) {
                list[count] = Hook(Write, kinds, keep);
                count += 1;
            }
        }

        std.debug.assert(count == list.len);

        return list;
    }
}

fn hooked(comptime wanted: u32) u32 {
    comptime {
        std.debug.assert(wanted != 0);

        var count: u32 = 0;

        for (writes) |Write| {
            if (Write.bits & wanted != 0) {
                count += 1;
            }
        }

        return count;
    }
}

/// The kinds as one bit each, so matching a write against a reader is one `and`.
fn bits_of(comptime kinds: []const Kind) u32 {
    comptime {
        std.debug.assert(kinds.len > 0);

        var bits: u32 = 0;

        for (kinds) |kind| {
            bits |= @as(u32, 1) << @intFromEnum(kind);
        }

        return bits;
    }
}

pub fn listed(kinds: []const Kind, kind: Kind) bool {
    std.debug.assert(kinds.len > 0);
    std.debug.assert(kinds.len <= std.meta.fields(Kind).len);

    for (kinds) |each| {
        if (each == kind) {
            return true;
        }
    }

    return false;
}

fn Hook(comptime Write: type, comptime kinds: []const Kind, comptime keep: Keep) type {
    const Operation = Write.Operation;

    return struct {
        pub const stage: sdk.middleware.Stage = .after;
        pub const operation = Operation.name;
        /// A move over many: each record from its transition event (`Moves`).
        pub const by_events = true;

        pub fn run(ctx: *Ctx, in: *Operation.In, out: *const Operation.Out) Error!void {
            std.debug.assert(ctx.parent != null);
            std.debug.assert(ctx.db.transaction_depth >= 1);

            var units: Units = .empty;

            try Write.units(ctx, in, out, &units);

            for (units.items) |unit| {
                if (listed(kinds, unit.kind)) {
                    keep(ctx, operation, unit);
                }
            }
        }
    };
}

fn add(ctx: *Ctx, units: *Units, kind: Kind, key: []const u8) Error!void {
    std.debug.assert(units.items.len < 1 << 20);

    if (key.len == 0) {
        return;
    }

    units.append(ctx.arena, .{
        .kind = kind,
        .key = key,
    }) catch return error.OutOfMemory;
}

const Side = enum { in, out };

/// A write whose unit is one field of its input or answer: a name, or a list of names.
fn Field(
    comptime Target: type,
    comptime kind: Kind,
    comptime side: Side,
    comptime name: []const u8,
) type {
    return struct {
        pub const Operation = Target;
        pub const kinds: []const Kind = &.{kind};
        pub const bits = bits_of(kinds);

        pub fn units(
            ctx: *Ctx,
            in: *const Operation.In,
            out: *const Operation.Out,
            list: *Units,
        ) Error!void {
            std.debug.assert(name.len > 0);
            std.debug.assert(list.items.len == 0);

            const value = if (side == .in) @field(in.*, name) else @field(out.*, name);

            if (comptime @TypeOf(value) == []const u8) {
                return add(ctx, list, kind, value);
            }

            for (value) |each| {
                try add(ctx, list, kind, each);
            }
        }
    };
}

const writes = [_]type{
    Field(content_types.Create, .content_type, .out, "handle"),
    Field(content_types.Update, .content_type, .out, "handle"),
    Field(content_types.Delete, .content_type, .out, "handle"),
    Field(taxonomies.Create, .taxonomy, .out, "handle"),
    Field(taxonomies.Update, .taxonomy, .out, "handle"),
    Field(taxonomies.Delete, .taxonomy, .out, "handle"),
    Field(custom_fields.Create, .field_group, .in, "group"),
    Field(custom_fields.Update, .field_group, .in, "group"),
    Field(custom_fields.Delete, .field_group, .in, "group"),
    PluginUpload,
    Field(plugins.Add, .plugin, .out, "name"),
    Field(plugins.Enable, .plugin, .in, "names"),
    Field(plugins.Disable, .plugin, .in, "names"),
    Field(plugins.Update, .plugin, .in, "name"),
    Field(plugins.CancelUpdate, .plugin, .in, "name"),
    Field(plugins.Rollback, .plugin, .in, "name"),
    Field(plugins.GrantRequest, .plugin, .in, "name"),
    Field(plugins.Revoke, .plugin, .in, "name"),
    Field(plugins.Deny, .plugin, .in, "name"),
    Field(plugins.SetGrant, .plugin, .in, "name"),
    Field(plugins.ChooseRemoval, .plugin, .in, "name"),
    PluginRemove,
    Field(plugin_sources.Build, .plugin, .in, "name"),
    Field(views.Create, .view, .out, "id"),
    Field(views.Update, .view, .in, "id"),
    Field(views.Delete, .view, .in, "id"),
    Field(view_defaults.SaveDefault, .view, .in, "type"),
    ViewReset,
    Field(snapshots.Restore, .record, .in, "id"),
    TrashRestore,
    Field(users.SetPassword, .user, .out, "user_id"),
    Field(user_manage.Update, .user, .out, "user_id"),
    Field(user_manage.Delete, .user, .out, "user_id"),
    Field(identity_manage.Link, .user, .out, "user_id"),
    Field(identity_manage.Unlink, .user, .out, "user_id"),
    IdentityLinked,
    ProjectPut,
} ++ documents(records, .record) ++ documents(terms, .term) ++ [_]type{
    Field(records.DeclineRequest, .record, .in, "id"),
};

/// A record's or a term's own writes, by the id given or made; a save only when it changed
/// something. A move over many is not here: each record is in its transition event.
fn documents(comptime namespace: type, comptime kind: Kind) [7]type {
    comptime std.debug.assert(kind == .record or kind == .term);

    return .{
        Field(namespace.Create, kind, .out, "id"),
        Saved(namespace.Save, kind),
        Field(namespace.Publish, kind, .in, "id"),
        Field(namespace.DiscardChanges, kind, .in, "id"),
        Field(namespace.Transition, kind, .in, "id"),
        Field(namespace.Delete, kind, .in, "id"),
        Field(namespace.Purge, kind, .in, "id"),
    };
}

fn Saved(comptime Target: type, comptime kind: Kind) type {
    return struct {
        pub const Operation = Target;
        pub const kinds: []const Kind = &.{kind};
        pub const bits = bits_of(kinds);

        pub fn units(
            ctx: *Ctx,
            in: *const Operation.In,
            out: *const Operation.Out,
            list: *Units,
        ) Error!void {
            std.debug.assert(in.id.len > 0);
            std.debug.assert(list.items.len == 0);

            if (!std.mem.eql(u8, out.outcome, "unchanged")) {
                try add(ctx, list, kind, in.id);
            }
        }
    };
}

/// The plugin the module was added to.
const PluginUpload = struct {
    pub const Operation = plugins.Upload;
    pub const kinds: []const Kind = &.{.plugin};
    pub const bits = bits_of(kinds);

    pub fn units(
        ctx: *Ctx,
        _: *const Operation.In,
        out: *const Operation.Out,
        list: *Units,
    ) Error!void {
        std.debug.assert(out.file.len > 0);
        std.debug.assert(list.items.len == 0);

        if (out.added) |added| {
            try add(ctx, list, .plugin, added.name);
        }
    }
};

/// The plugin, and the content types chosen to go with it.
const PluginRemove = struct {
    pub const Operation = plugins.Remove;
    pub const kinds: []const Kind = &.{ .plugin, .content_type };
    pub const bits = bits_of(kinds);

    pub fn units(
        ctx: *Ctx,
        in: *const Operation.In,
        out: *const Operation.Out,
        list: *Units,
    ) Error!void {
        std.debug.assert(in.name.len > 0);
        std.debug.assert(list.items.len == 0);

        for (out.types_removed) |handle| {
            try add(ctx, list, .content_type, handle);
        }

        try add(ctx, list, .plugin, in.name);
    }
};

/// A type's default view, only when there was one to forget.
const ViewReset = struct {
    pub const Operation = view_defaults.ResetDefault;
    pub const kinds: []const Kind = &.{.view};
    pub const bits = bits_of(kinds);

    pub fn units(
        ctx: *Ctx,
        in: *const Operation.In,
        out: *const Operation.Out,
        list: *Units,
    ) Error!void {
        std.debug.assert(in.type.len > 0);
        std.debug.assert(list.items.len == 0);

        if (out.reset) {
            try add(ctx, list, .view, in.type);
        }
    }
};

/// What came back, by the kind its trash entry names.
const TrashRestore = struct {
    pub const Operation = trash.Restore;
    pub const kinds: []const Kind = &.{ .content_type, .taxonomy, .plugin };
    pub const bits = bits_of(kinds);

    pub fn units(
        ctx: *Ctx,
        in: *const Operation.In,
        out: *const Operation.Out,
        list: *Units,
    ) Error!void {
        std.debug.assert(in.id.len > 0);
        std.debug.assert(list.items.len == 0);

        const kind = std.meta.stringToEnum(Kind, out.kind) orelse return;

        if (listed(kinds, kind)) {
            try add(ctx, list, kind, out.key);
        }
    }
};

/// A sign-in through a provider that linked the identity to the account with its email.
const IdentityLinked = struct {
    pub const Operation = identity.SignIn;
    pub const kinds: []const Kind = &.{.user};
    pub const bits = bits_of(kinds);

    pub fn units(
        ctx: *Ctx,
        _: *const Operation.In,
        out: *const Operation.Out,
        list: *Units,
    ) Error!void {
        std.debug.assert(out.user_id.len > 0);
        std.debug.assert(list.items.len == 0);

        if (out.linked) {
            try add(ctx, list, .user, out.user_id);
        }
    }
};

/// Every unit put but those already as given; a type or taxonomy by its handle.
const ProjectPut = struct {
    pub const Operation = project_put.Put;
    pub const kinds: []const Kind = &.{
        .record,
        .term,
        .content_type,
        .taxonomy,
        .field_group,
        .plugin,
    };
    pub const bits = bits_of(kinds);

    pub fn units(
        ctx: *Ctx,
        _: *const Operation.In,
        out: *const Operation.Out,
        list: *Units,
    ) Error!void {
        std.debug.assert(out.put.len <= project_put.units_max);
        std.debug.assert(list.items.len == 0);

        for (out.put) |done| {
            const kind = std.meta.stringToEnum(Kind, done.kind) orelse continue;

            if (!listed(kinds, kind)) {
                continue;
            }

            const by_handle = kind == .content_type or kind == .taxonomy;

            if (!std.mem.eql(u8, done.outcome, "unchanged")) {
                try add(ctx, list, kind, if (by_handle) done.handle else done.id);
            }
        }
    }
};

test "a reader hooks only the writes that may change its kinds" {
    const views_hooked = comptime hooked(bits_of(&.{.view}));
    const users_hooked = comptime hooked(bits_of(&.{.user}));
    const plugins_hooked = comptime hooked(bits_of(&.{.plugin}));
    const records_hooked = comptime hooked(bits_of(&.{.record}));
    const terms_hooked = comptime hooked(bits_of(&.{.term}));
    const every = comptime hooks(std.enums.values(Kind), keep_nothing);

    try std.testing.expectEqual(@as(u32, 5), views_hooked);
    try std.testing.expectEqual(@as(u32, 6), users_hooked);
    try std.testing.expect(plugins_hooked >= 15);
    // Create, save, publish, discard, transition, delete, purge, decline; a snapshot
    // restored; `project.put`.
    try std.testing.expectEqual(@as(u32, 10), records_hooked);
    try std.testing.expectEqual(@as(u32, 8), terms_hooked);
    try std.testing.expectEqual(writes.len, every.len);
}

test {
    _ = moves;
}

fn keep_nothing(ctx: *Ctx, operation: []const u8, unit: Unit) void {
    std.debug.assert(operation.len > 0);
    std.debug.assert(unit.key.len > 0);
    std.debug.assert(ctx.now_ms >= 0);
}
