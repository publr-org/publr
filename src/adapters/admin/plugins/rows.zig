//! The plugin operations' answers as the pages draw them: requests low to high with the
//! buttons each state allows, the content types for the access choice.
const std = @import("std");
const admin = @import("../../admin.zig");
const registry = @import("../../../server/registry.zig");
const plugin_operations = @import("../../../operations/plugin.zig");
const types = @import("../../../operations/content_type.zig");

const Error = admin.Error;
const Session = admin.Session;

/// Requests as rows of a page's `Row` type, low tier first; `buttons` gives each the changes
/// its state allows.
pub fn requests(
    comptime Row: type,
    arena: std.mem.Allocator,
    list: []const plugin_operations.Request,
    domains: []const []const u8,
    buttons: bool,
) Error![]const Row {
    std.debug.assert(list.len <= 256);
    std.debug.assert(domains.len <= 64);

    var rows: std.ArrayList(Row) = .empty;

    for ([_]@TypeOf(list[0].tier){ .low, .medium, .high }) |tier| {
        for (list) |request| {
            if (request.tier == tier) {
                try rows.append(arena, try row_of(Row, arena, request, domains, buttons));
            }
        }
    }

    return rows.items;
}

fn row_of(
    comptime Row: type,
    arena: std.mem.Allocator,
    request: plugin_operations.Request,
    domains: []const []const u8,
    buttons: bool,
) Error!Row {
    std.debug.assert(request.key.len > 0);

    const state = request.state;
    const note: []const u8 = if (state == .unavailable)
        "Unavailable: nothing installed provides it; the plugin runs without it"
    else if (std.mem.eql(u8, request.key, "http.fetch") and domains.len > 0)
        try std.fmt.allocPrint(arena, "Only {s}", .{
            try std.mem.join(arena, ", ", domains),
        })
    else
        "";

    return .{
        .key = request.key,
        .sentence = request.sentence,
        .reason = request.reason,
        .tier = @tagName(request.tier),
        .state = @tagName(state),
        .note = note,
        .can_grant = buttons and (state == .pending or state == .denied),
        .can_revoke = buttons and state == .granted,
        .can_deny = buttons and state == .pending,
    };
}

/// An update's requests split in two: what the running version does not hold (new), and what
/// it holds already. `held` is the running version's requests.
pub fn split_update(
    arena: std.mem.Allocator,
    list: []const plugin_operations.Request,
    held: []const plugin_operations.Request,
    domains: []const []const u8,
) Error!struct {
    fresh: []const admin.views.PluginReview.RequestsItem,
    held: []const admin.views.PluginReview.GrantedItem,
} {
    std.debug.assert(list.len <= 256);
    std.debug.assert(held.len <= 256);

    var fresh: std.ArrayList(plugin_operations.Request) = .empty;
    var kept: std.ArrayList(plugin_operations.Request) = .empty;

    for (list) |request| {
        const holds = for (held) |current| {
            if (std.mem.eql(u8, current.key, request.key) and current.state == .granted) {
                break true;
            }
        } else false;
        const target = if (holds) &kept else &fresh;

        try target.append(arena, request);
    }

    const Fresh = admin.views.PluginReview.RequestsItem;
    const Held = admin.views.PluginReview.GrantedItem;

    return .{
        .fresh = try requests(Fresh, arena, fresh.items, domains, false),
        .held = try requests(Held, arena, kept.items, domains, false),
    };
}

/// Every content type as a page's `TypeRow`, ticked when a `specific` access names it.
pub fn type_rows(
    comptime TypeRow: type,
    session: *Session,
    ticked: []const []const u8,
) Error![]const TypeRow {
    std.debug.assert(ticked.len <= 64);

    const listed = registry.SDK.dispatch(&session.ctx, types.List, .{}) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else &.{};
    };
    var rows: std.ArrayList(TypeRow) = .empty;

    for (listed.types) |summary| {
        var checked = false;

        for (ticked) |handle| {
            checked = checked or std.mem.eql(u8, handle, summary.handle);
        }

        try rows.append(session.arena, .{
            .handle = summary.handle,
            .name = summary.name,
            .checked = checked,
        });
    }

    return rows.items;
}

/// The access posted with a form: `scope` and the ticked `types`.
pub fn access_of(
    arena: std.mem.Allocator,
    form: *const admin.Form,
) error{ OutOfMemory, Invalid }!plugin_operations.ContentAccess {
    std.debug.assert(form.len <= admin.form_pairs_max);

    const scope_text = form.text("scope") orelse "public";
    const Scope = @TypeOf(@as(plugin_operations.ContentAccess, .{}).scope);
    const scope = std.meta.stringToEnum(Scope, scope_text) orelse return error.Invalid;
    var ticked: std.ArrayList([]const u8) = .empty;

    for (form.pairs[0..form.len]) |pair| {
        if (std.mem.eql(u8, pair.name, "types") and pair.value.len > 0) {
            try ticked.append(arena, pair.value);
        }
    }

    return .{ .scope = scope, .types = ticked.items };
}
