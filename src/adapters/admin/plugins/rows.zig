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
    session: *const Session,
    list: []const plugin_operations.Request,
    domains: []const []const u8,
    buttons: bool,
) Error![]const Row {
    std.debug.assert(list.len <= 256);
    std.debug.assert(domains.len <= 64);

    const arena = session.arena;

    var rows: std.ArrayList(Row) = .empty;

    for ([_]@TypeOf(list[0].tier){ .low, .medium, .high }) |tier| {
        for (list) |request| {
            if (request.tier == tier) {
                try rows.append(arena, try row_of(Row, session, request, domains, buttons));
            }
        }
    }

    return rows.items;
}

fn row_of(
    comptime Row: type,
    session: *const Session,
    request: plugin_operations.Request,
    domains: []const []const u8,
    buttons: bool,
) Error!Row {
    std.debug.assert(request.key.len > 0);

    const state = request.state;
    const fetches = std.mem.eql(u8, request.key, "http.fetch");
    const note: []const u8 = if (state == .unavailable)
        try session.translated(
            "Unavailable: nothing installed provides it; the plugin runs without it",
        )
    else if (fetches and anywhere(domains))
        try session.translated("Any address on the internet")
    else if (fetches and domains.len > 0)
        try session.translated_with("Only {domains}", &.{.{
            .name = "domains",
            .value = try std.mem.join(session.arena, ", ", domains),
        }})
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
    session: *const Session,
    list: []const plugin_operations.Request,
    held: []const plugin_operations.Request,
    domains: []const []const u8,
) Error!struct {
    fresh: []const admin.views.PluginReview.RequestsItem,
    held: []const admin.views.PluginReview.GrantedItem,
} {
    std.debug.assert(list.len <= 256);
    std.debug.assert(held.len <= 256);

    const arena = session.arena;
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
        .fresh = try requests(Fresh, session, fresh.items, domains, false),
        .held = try requests(Held, session, kept.items, domains, false),
    };
}

/// Every content type as a page's `TypeRow`, ticked when a `specific` access names it.
pub fn type_rows(
    comptime TypeRow: type,
    session: *Session,
    ticked: []const []const u8,
) Error![]const TypeRow {
    std.debug.assert(ticked.len <= 64);

    const listed = registry.SDK.dispatch(&session.ctx, types.List, .{
        .limit = @import("../../../sdk/operation.zig").page_limit_max,
    }) catch |err| {
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

    // One ticked past the first types listed: offered too, so saving keeps it.
    for (ticked) |handle| {
        const shown = for (rows.items) |row| {
            if (std.mem.eql(u8, row.handle, handle)) {
                break true;
            }
        } else false;

        if (!shown) {
            try rows.append(session.arena, .{
                .handle = handle,
                .name = handle,
                .checked = true,
            });
        }
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

    return .{
        .scope = scope,
        .types = ticked.items,
    };
}

/// Whether a plugin may send requests anywhere: it declared `*` among its domains.
fn anywhere(domains: []const []const u8) bool {
    std.debug.assert(domains.len <= 64);

    for (domains) |domain| {
        if (std.mem.eql(u8, domain, "*")) {
            return true;
        }
    }

    return false;
}
