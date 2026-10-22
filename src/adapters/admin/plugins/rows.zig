//! The plugin operations' answers as the pages draw them: requests low to high, each with
//! a switch for its key and one per flag it asked for; and what a posted form switched.
const std = @import("std");
const admin = @import("../../admin.zig");
const plugin_operations = @import("../../../operations/plugin.zig");
const permission = @import("../../../model/permission.zig");

const Error = admin.Error;
const Session = admin.Session;

/// How a page shows requests: as they stand, with switches as they stand (the plugin's
/// page), or with every key switched on as asked (the review before enabling).
pub const Mode = enum { read_only, switches, review };

pub const Secret = plugin_operations.Detail.Secret;

/// Requests as rows of a page's `Row` type, low tier first; `secrets` (what the plugin
/// declares) under its `http.fetch` row.
pub fn requests(
    comptime Row: type,
    session: *const Session,
    list: []const plugin_operations.Request,
    secrets: []const Secret,
    mode: Mode,
) Error![]const Row {
    std.debug.assert(list.len <= 256);
    std.debug.assert(@intFromEnum(mode) <= 2);

    const arena = session.arena;

    var rows: std.ArrayList(Row) = .empty;

    for ([_]@TypeOf(list[0].tier){ .low, .medium, .high }) |tier| {
        for (list) |request| {
            if (request.tier == tier) {
                var row = try row_of(Row, session, request, mode);

                if (std.mem.eql(u8, request.key, "http.fetch")) {
                    row.secrets = try secret_rows(Row, session, secrets);
                }

                try rows.append(arena, row);
            }
        }
    }

    return rows.items;
}

/// Each declared secret as the row shows it: set or not, and who else shares it.
fn secret_rows(
    comptime Row: type,
    session: *const Session,
    secrets: []const Secret,
) Error!@FieldType(Row, "secrets") {
    std.debug.assert(secrets.len <= 32);
    std.debug.assert(session.signed_in());

    const Shown = @typeInfo(@FieldType(Row, "secrets")).pointer.child;
    const shown = try session.arena.alloc(Shown, secrets.len);

    for (secrets, shown) |secret, *one| {
        one.* = .{
            .name = secret.name,
            .label = secret.label,
            .help = secret.help,
            .set = secret.set,
            .status = try status_of(session, secret),
        };
    }

    return shown;
}

fn status_of(session: *const Session, secret: Secret) Error![]const u8 {
    std.debug.assert(secret.name.len > 0);

    if (!secret.set) {
        return session.translated("Not set", .{});
    }

    if (secret.shared_with.len == 0) {
        return session.translated("Set", .{});
    }

    return session.translated("Set, shared with {plugins}", .{
        .values = &.{.{
            .name = "plugins",
            .value = try std.mem.join(session.arena, ", ", secret.shared_with),
        }},
    });
}

/// The labels of the secrets with no value yet, joined; empty when every one is set.
pub fn missing(session: *const Session, secrets: []const Secret) Error![]const u8 {
    std.debug.assert(secrets.len <= 32);
    std.debug.assert(session.signed_in());

    var labels: std.ArrayList([]const u8) = .empty;

    for (secrets) |secret| {
        if (!secret.set) {
            try labels.append(session.arena, secret.label);
        }
    }

    return std.mem.join(session.arena, ", ", labels.items);
}

/// What the form typed for each declared secret: `secret:<NAME>` with a value. Empty ones
/// are left as they are: a secret is optional.
pub fn secrets_posted(
    arena: std.mem.Allocator,
    form: *const admin.Form,
    secrets: []const Secret,
) error{OutOfMemory}![]const Typed {
    std.debug.assert(form.len <= admin.form_pairs_max);
    std.debug.assert(secrets.len <= 32);

    var typed: std.ArrayList(Typed) = .empty;

    for (secrets) |secret| {
        const field = try std.fmt.allocPrint(arena, "secret:{s}", .{secret.name});
        const value = std.mem.trim(u8, form.text(field) orelse "", " \t\r\n");

        if (value.len > 0) {
            try typed.append(arena, .{
                .name = secret.name,
                .value = value,
            });
        }
    }

    return typed.items;
}

pub const Typed = struct {
    name: []const u8,
    value: []const u8,
};

fn row_of(
    comptime Row: type,
    session: *const Session,
    request: plugin_operations.Request,
    mode: Mode,
) Error!Row {
    std.debug.assert(request.key.len > 0);

    const state = request.state;
    const fetches = std.mem.eql(u8, request.key, "http.fetch");
    const domains = request.domains;
    const editable = mode != .read_only and state != .unavailable;
    const note: []const u8 = if (state == .unavailable)
        try session.translated(
            "Unavailable: nothing installed provides it; the plugin runs without it",
            .{},
        )
    else if (fetches and editable)
        ""
    else if (fetches and request.new_domains.len > 0)
        try session.translated("New domains: {domains}", .{
            .values = &.{.{
                .name = "domains",
                .value = try std.mem.join(session.arena, ", ", request.new_domains),
            }},
        })
    else if (fetches and domains.len > 0)
        try only(session, domains)
    else if (fetches)
        try session.translated("No domains: it can reach nothing", .{})
    else if (request.names.len > 0)
        try only(session, request.names)
    else
        "";
    const Flag = @typeInfo(@FieldType(Row, "flags")).pointer.child;
    const flags = try session.arena.alloc(Flag, request.flags.len);

    for (request.flags, flags) |flag, *shown| {
        shown.* = .{
            .name = @tagName(flag.name),
            .label = try flag_label(session, request.key, flag.name),
            .on = flag.on,
        };
    }

    return .{
        .key = request.key,
        .sentence = request.sentence,
        .reason = request.reason,
        .tier = @tagName(request.tier),
        .state = @tagName(state),
        .note = note,
        .on = state == .granted or (mode == .review and state != .unavailable),
        .editable = editable,
        .flags = flags,
        .takes_domains = fetches,
        .domains = try std.mem.join(session.arena, "\n", domains),
        .anywhere = fetches and anywhere(domains),
        .secrets = &.{},
    };
}

fn only(session: *const Session, names: []const []const u8) Error![]const u8 {
    std.debug.assert(names.len > 0);
    std.debug.assert(names.len <= 64);

    return session.translated("Only {names}", .{
        .values = &.{.{
            .name = "names",
            .value = try std.mem.join(session.arena, ", ", names),
        }},
    });
}

/// What switching a flag on lets the plugin do, in plain words.
fn flag_label(session: *const Session, key: []const u8, flag: permission.Flag) Error![]const u8 {
    std.debug.assert(key.len > 0);
    std.debug.assert(@intFromEnum(flag) < 4);

    const media = std.mem.startsWith(u8, key, "media.");
    const terms = std.mem.startsWith(u8, key, "terms.");

    if (terms) {
        return switch (flag) {
            .drafts => session.translated("Also draft terms", .{}),
            .private => session.translated("Also private taxonomies", .{}),
            .internal => session.translated("Also internal taxonomies", .{}),
            .publish => session.translated("Put changes live without asking", .{}),
        };
    }

    return switch (flag) {
        .drafts => session.translated("Also drafts, unpublished changes and history", .{}),
        .private => if (media)
            session.translated("Also private files", .{})
        else
            session.translated("Also private content types", .{}),
        .internal => session.translated("Also other plugins' internal records", .{}),
        .publish => session.translated("Put changes live without asking", .{}),
    };
}

/// An update's requests split in two: what the running version does not hold, or holds but
/// the new version asks more of (new domains), and what it holds already. `held` is the
/// running version's requests.
pub fn split_update(
    session: *const Session,
    list: []const plugin_operations.Request,
    held: []const plugin_operations.Request,
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
        const target = if (holds and request.new_domains.len == 0) &kept else &fresh;

        try target.append(arena, request);
    }

    const Fresh = admin.views.PluginReview.RequestsItem;
    const Held = admin.views.PluginReview.GrantedItem;

    return .{
        .fresh = try requests(Fresh, session, fresh.items, &.{}, .read_only),
        .held = try requests(Held, session, kept.items, &.{}, .read_only),
    };
}

/// What a posted form switched, for each request `list` shows: the key on or off, each flag
/// it asked for on or off. Only the requests that changed, unless `every` (a review, where
/// each one is decided).
pub fn choices_of(
    arena: std.mem.Allocator,
    form: *const admin.Form,
    list: []const plugin_operations.Request,
    every: bool,
) error{OutOfMemory}![]const plugin_operations.Choice {
    std.debug.assert(form.len <= admin.form_pairs_max);
    std.debug.assert(list.len <= 256);

    var chosen: std.ArrayList(plugin_operations.Choice) = .empty;

    for (list) |request| {
        if (request.state == .unavailable or !posted(form, "keys", request.key)) {
            continue;
        }

        const on = posted(form, "on", request.key);
        var choice: plugin_operations.Choice = .{
            .key = request.key,
        };
        var changed = every or on != (request.state == .granted);

        if (changed) {
            choice.on = on;
        }

        for (request.flags) |flag| {
            const set = posted(form, @tagName(flag.name), request.key);

            switch (flag.name) {
                .drafts => choice.drafts = set,
                .private => choice.private = set,
                .internal => choice.internal = set,
                .publish => choice.publish = set,
            }

            changed = changed or set != flag.on;
        }

        if (std.mem.eql(u8, request.key, "http.fetch")) {
            const domains = try domains_posted(arena, form);

            choice.domains = domains;
            changed = changed or !same(domains, request.domains);
        }

        if (changed) {
            try chosen.append(arena, choice);
        }
    }

    return chosen.items;
}

/// The domains the form's box holds, one a line, trimmed and lower-cased; empty lines left
/// out. Checked where they are saved.
fn domains_posted(
    arena: std.mem.Allocator,
    form: *const admin.Form,
) error{OutOfMemory}![]const []const u8 {
    std.debug.assert(form.len <= admin.form_pairs_max);

    const text = form.text("domains") orelse "";
    var domains: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n, ");

    while (lines.next()) |line| {
        if (domains.items.len == 64) {
            break;
        }

        try domains.append(arena, try std.ascii.allocLowerString(arena, line));
    }

    std.debug.assert(domains.items.len <= 64);

    return domains.items;
}

fn same(left: []const []const u8, right: []const []const u8) bool {
    std.debug.assert(left.len <= 64);

    if (left.len != right.len) {
        return false;
    }

    for (left, right) |one, other| {
        if (!std.mem.eql(u8, one, other)) {
            return false;
        }
    }

    return true;
}

/// Whether the form posted `name` with `value`: a ticked switch, a listed key.
fn posted(form: *const admin.Form, name: []const u8, value: []const u8) bool {
    std.debug.assert(name.len > 0);
    std.debug.assert(form.len <= admin.form_pairs_max);

    for (form.pairs[0..form.len]) |pair| {
        if (std.mem.eql(u8, pair.name, name) and std.mem.eql(u8, pair.value, value)) {
            return true;
        }
    }

    return false;
}

/// Whether a plugin may send requests anywhere: `*` is among its domains.
fn anywhere(domains: []const []const u8) bool {
    std.debug.assert(domains.len <= 64);

    for (domains) |domain| {
        if (std.mem.eql(u8, domain, "*")) {
            return true;
        }
    }

    return false;
}
