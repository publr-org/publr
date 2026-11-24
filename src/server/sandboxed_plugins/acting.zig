//! Who a plugin's entry runs as and what it reads around its input: the plugin made the
//! caller for the length of the call, holding its grants narrowed to the roles of the
//! account it acts for, and the head every entry takes (when, for whom, who is calling).
const std = @import("std");
const sdk = @import("../../sdk.zig");
const wire = @import("../../sdk/plugin/wire.zig");
const caller_view = @import("../../sdk/plugin/caller_view.zig");
const HostApi = @import("../../sdk/plugin/context.zig").HostApi;
const Loaded = @import("loaded.zig").Loaded;

/// What every entry reads around its input: when it runs, for whom, who is calling.
pub const Head = struct {
    now_ms: i64,
    on_behalf_of: ?[]const u8,
    visitor: []const u8,
    caller: wire.Caller,
    language: []const u8,
    last: bool,
};

/// The plugin made the caller while one of its entries runs, and what it stands in for.
pub const Acting = struct {
    ctx: *sdk.Ctx,
    caller: sdk.Caller,
    plugin: []const u8,
    handed_by: []const u8,

    pub fn begin(
        loaded: *Loaded,
        ctx: *sdk.Ctx,
        access: *const sdk.plugin_access.Access,
        entry: u32,
    ) Acting {
        const acting: Acting = .{
            .ctx = ctx,
            .caller = ctx.caller,
            .plugin = ctx.plugin,
            .handed_by = ctx.handed_by,
        };
        const saved = ctx.caller;

        std.debug.assert(entry < loaded.manifest.operations.len + loaded.manifest.hooks.len +
            loaded.manifest.jobs.len + loaded.manifest.location_rules.len * 2 +
            loaded.manifest.field_kinds.len * 3 + loaded.manifest.dimensions.len);

        ctx.plugin = loaded.name();

        // Only an operation moves the ledger accounts its caller handed over; a hook never.
        if (entry >= loaded.manifest.operations.len) {
            ctx.handed_by = "";
        }

        ctx.caller = .{
            .plugin = .{
                .name = loaded.name(),
                .on_behalf_of = saved.user_id(),
                .access = access,
                .roles = saved.roles() orelse if (saved == .plugin) saved.plugin.roles else null,
            },
        };

        return acting;
    }

    pub fn end(acting: Acting) void {
        std.debug.assert(acting.ctx.caller == .plugin);

        acting.ctx.caller = acting.caller;
        acting.ctx.handed_by = acting.handed_by;
        acting.ctx.plugin = acting.plugin;
    }
};

/// What the entry reads around its input, as the call stands before the plugin runs.
pub fn head_of(ctx: *sdk.Ctx, last: bool) Head {
    const host: HostApi = .{
        .inner = ctx,
    };

    std.debug.assert(ctx.now_ms >= 0);

    return .{
        .now_ms = ctx.now_ms,
        .on_behalf_of = ctx.caller.user_id(),
        .visitor = ctx.visitor,
        .caller = caller_of(ctx),
        .language = host.language(),
        .last = last,
    };
}

/// The caller as a compiled-in plugin's `ctx.caller()` sees it.
fn caller_of(ctx: *sdk.Ctx) wire.Caller {
    std.debug.assert(ctx.now_ms >= 0);

    const host: HostApi = .{
        .inner = ctx,
    };
    const view = host.caller();

    std.debug.assert(view.visitor.len == ctx.visitor.len);

    return .{
        .from = caller_view.kind_of(view.from),
        .plugin = caller_view.plugin_of(view.from),
        .referer = view.referer,
        .signed_in = view.signed_in(),
        .roles = ctx.caller.roles() orelse &.{},
        .granted = view.granted(),
    };
}
