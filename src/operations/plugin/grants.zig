//! A plugin's permissions switched by a person: a key on or off, and each flag it asked for
//! on or off. Never more than it asked for; a key switched off is denied, on is granted.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const state = @import("state.zig");

const Error = sdk.Error;
const permission = model.permission;
const outside = model.outside;
const sandboxed_plugin = model.sandboxed_plugin;

/// One request as a person left it: the key on or off, and the flags it asked for, each on
/// or off (one not given stays as it is).
pub const Choice = struct {
    key: []const u8,
    on: ?bool = null,
    drafts: ?bool = null,
    private: ?bool = null,
    internal: ?bool = null,
    publish: ?bool = null,
    /// `http.fetch`'s domains as the person left them, replacing the list; null: as it is.
    domains: ?[]const []const u8 = null,
};

pub const choices_max: u32 = sandboxed_plugin.requests_max;

/// Applies `choice` to the decoded row: the key granted, denied or left, its flags stored.
/// Not found for a key the plugin does not ask for; invalid for a flag it did not ask for,
/// or switching on what nothing installed provides.
pub fn apply(arena: std.mem.Allocator, decoded: *state.Decoded, choice: Choice) Error!void {
    std.debug.assert(choice.key.len > 0);
    std.debug.assert(decoded.granted.len <= sandboxed_plugin.requests_max);

    const manifest = &decoded.manifest;
    const asked = sandboxed_plugin.requests(&permission.core, manifest, arena) catch |err| {
        return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
    };
    const request = find(asked, choice.key) orelse return error.NotFound;

    const on = choice.on orelse false;

    if (on and !request.available) {
        return error.Invalid;
    }

    if (request.asked) |as_asked| {
        decoded.grants = try with_flags(arena, decoded.grants, as_asked, choice);
    } else if (flagged(choice) or choice.domains != null) {
        return error.Invalid;
    }

    if (choice.on == null) {
        return;
    }

    if (on) {
        decoded.granted = try state.with(arena, decoded.granted, choice.key);
        decoded.denied = try state.without(arena, decoded.denied, choice.key);
    } else {
        decoded.granted = try state.without(arena, decoded.granted, choice.key);
        decoded.denied = try state.with(arena, decoded.denied, choice.key);
    }
}

fn find(asked: []const sandboxed_plugin.Request, key: []const u8) ?sandboxed_plugin.Request {
    std.debug.assert(key.len > 0);
    std.debug.assert(asked.len <= sandboxed_plugin.requests_max);

    for (asked) |candidate| {
        if (std.mem.eql(u8, candidate.key, key)) {
            return candidate;
        }
    }

    return null;
}

/// The stored grants with `choice`'s flags set on its key's.
fn with_flags(
    arena: std.mem.Allocator,
    grants: []const permission.Held,
    as_asked: permission.Held,
    choice: Choice,
) Error![]const permission.Held {
    std.debug.assert(as_asked.key.len > 0);
    std.debug.assert(grants.len <= sandboxed_plugin.requests_max);

    var set = sandboxed_plugin.as_set(as_asked, grants);
    const wanted = [_]?bool{ choice.drafts, choice.private, choice.internal, choice.publish };

    for (wanted, 0..) |value_or_null, index| {
        const flag: permission.Flag = @enumFromInt(index);
        const value = value_or_null orelse continue;

        if (value and !as_asked.flag(flag)) {
            return error.Invalid;
        }

        set.set(flag, value);
    }

    if (choice.domains) |domains| {
        const entry = permission.find(&permission.core, as_asked.key) orelse return error.Invalid;

        if (entry.narrowing != .domains) {
            return error.Invalid;
        }

        set.domains = try domains_checked(arena, domains);
    }

    var kept: std.ArrayList(permission.Held) = .empty;

    for (grants) |held| {
        if (!std.mem.eql(u8, held.key, choice.key)) {
            kept.append(arena, held) catch return error.OutOfMemory;
        }
    }

    kept.append(arena, set) catch return error.OutOfMemory;

    return kept.items;
}

/// `domains` each once, every one exact, `*.example.com` or `*`; invalid otherwise.
fn domains_checked(
    arena: std.mem.Allocator,
    domains: []const []const u8,
) Error![]const []const u8 {
    std.debug.assert(outside.domains_max > 0);

    if (domains.len > outside.domains_max) {
        return error.Invalid;
    }

    var kept: std.ArrayList([]const u8) = .empty;

    for (domains) |domain| {
        if (!outside.valid_domain(domain)) {
            return error.Invalid;
        }

        if (!permission.contains(kept.items, domain)) {
            kept.append(arena, domain) catch return error.OutOfMemory;
        }
    }

    std.debug.assert(kept.items.len <= domains.len);

    return kept.items;
}

fn flagged(choice: Choice) bool {
    std.debug.assert(choice.key.len > 0);

    const wanted = [_]?bool{ choice.drafts, choice.private, choice.internal, choice.publish };

    for (wanted) |value_or_null| {
        if (value_or_null orelse false) {
            return true;
        }
    }

    return false;
}

/// What is wrong with a manifest's permissions, if anything: an option its key does not take
/// (a build refuses it; a module made otherwise is refused here).
pub fn problem(manifest: *const sandboxed_plugin.Manifest) ?[]const u8 {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(manifest.permissions.len <= sandboxed_plugin.requests_max);

    for (manifest.permissions) |*ask| {
        const entry = permission.find(&permission.core, ask.key) orelse continue;
        const held = ask.held();

        if (ask.records.len > 0 and entry.narrowing != .records) {
            return "a permission names content types it does not take";
        }

        if (ask.taxonomies.len > 0 and entry.narrowing != .taxonomies) {
            return "a permission names taxonomies it does not take";
        }

        if (ask.domains.len > 0 and entry.narrowing != .domains) {
            return "a permission names domains it does not take";
        }

        if (ask.domains.len > outside.domains_max) {
            return "http.fetch lists more than 32 domains";
        }

        for (ask.domains) |domain| {
            if (!outside.valid_domain(domain)) {
                return "http.fetch lists a domain that is none of: a host name, *.name, *";
            }
        }

        if (ask.records.len > sandboxed_plugin.names_max or
            ask.taxonomies.len > sandboxed_plugin.names_max)
        {
            return "a permission names too many types";
        }

        inline for (std.meta.fields(permission.Flag)) |field| {
            const flag: permission.Flag = @enumFromInt(field.value);

            const takes = std.mem.indexOfScalar(permission.Flag, entry.flags, flag) != null;

            if (held.flag(flag) and !takes) {
                return "a permission asks for a flag its key does not take";
            }
        }
    }

    return secrets_problem(manifest);
}

/// What is wrong with the secrets a manifest declares, if anything.
fn secrets_problem(manifest: *const sandboxed_plugin.Manifest) ?[]const u8 {
    std.debug.assert(manifest.name.len > 0);

    const model_secrets = @import("../../model/secrets.zig");

    if (manifest.secrets.len > model_secrets.declared_max) {
        return "more than 32 secrets";
    }

    for (manifest.secrets) |secret| {
        if (!model_secrets.valid_name(secret.name) or secret.label.len == 0) {
            return "a secret is not named like an environment variable, or has no label";
        }
    }

    return null;
}

const test_manifest: sandboxed_plugin.Manifest = .{
    .name = "prices",
    .version = "0.1.0",
    .summary = "Prices",
    .permissions = &.{ .{
        .key = "records.write",
        .records = &.{"post"},
        .publish = true,
        .reason = "Puts new prices live",
    }, .{
        .key = "users.read",
        .reason = "Mails buyers",
    } },
};

test "a choice switches a flag or the key, never past what was asked" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var decoded: state.Decoded = .{
        .row = undefined,
        .manifest = test_manifest,
        .granted = &.{"records.write"},
        .denied = &.{},
        .grants = &.{},
    };

    try apply(arena, &decoded, .{
        .key = "records.write",
        .on = true,
        .publish = false,
    });
    try std.testing.expect(!sandboxed_plugin.as_set(
        test_manifest.permissions[0].held(),
        decoded.grants,
    ).publish);
    try std.testing.expectError(error.Invalid, apply(arena, &decoded, .{
        .key = "records.write",
        .on = true,
        .drafts = true,
    }));
    try std.testing.expectError(error.NotFound, apply(arena, &decoded, .{
        .key = "records.read",
        .on = true,
    }));

    try apply(arena, &decoded, .{
        .key = "users.read",
        .on = false,
    });
    try std.testing.expect(permission.contains(decoded.denied, "users.read"));

    try apply(arena, &decoded, .{
        .key = "records.write",
        .on = true,
        .publish = true,
    });
    try std.testing.expect(sandboxed_plugin.as_set(
        test_manifest.permissions[0].held(),
        decoded.grants,
    ).publish);
    try std.testing.expectEqual(@as(usize, 2), decoded.grants.len);
}

test "a person adds and removes http.fetch's domains; only valid ones, only on that key" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var manifest = test_manifest;

    manifest.permissions = &.{.{
        .key = "http.fetch",
        .domains = &.{"api.supplier.com"},
        .reason = "Downloads prices",
    }};

    var decoded: state.Decoded = .{
        .row = undefined,
        .manifest = manifest,
        .granted = &.{"http.fetch"},
        .denied = &.{},
        .grants = &.{},
    };
    const asked = manifest.permissions[0].held();

    try std.testing.expectEqualStrings("api.supplier.com", sandboxed_plugin.as_set(
        asked,
        decoded.grants,
    ).domains[0]);
    try apply(arena, &decoded, .{
        .key = "http.fetch",
        .domains = &.{ "chat.example.com", "*.cdn.example.com", "chat.example.com" },
    });

    const set = sandboxed_plugin.as_set(asked, decoded.grants);

    try std.testing.expectEqual(@as(usize, 2), set.domains.len);
    try std.testing.expectEqualStrings("*.cdn.example.com", set.domains[1]);
    try std.testing.expectError(error.Invalid, apply(arena, &decoded, .{
        .key = "http.fetch",
        .domains = &.{"https://example.com"},
    }));

    try apply(arena, &decoded, .{
        .key = "http.fetch",
        .domains = &.{},
    });
    const emptied = sandboxed_plugin.as_set(asked, decoded.grants);

    try std.testing.expectEqual(@as(usize, 0), emptied.domains.len);

    decoded.manifest = test_manifest;
    try std.testing.expectError(error.Invalid, apply(arena, &decoded, .{
        .key = "records.write",
        .domains = &.{"example.com"},
    }));
}

test "a manifest's options are those its keys take" {
    try std.testing.expect(problem(&test_manifest) == null);

    var wrong = test_manifest;

    wrong.permissions = &.{.{
        .key = "users.read",
        .publish = true,
        .reason = "A flag users.read lacks",
    }};
    try std.testing.expect(problem(&wrong) != null);

    wrong.permissions = &.{.{
        .key = "terms.read",
        .records = &.{"post"},
        .reason = "Types on terms",
    }};
    try std.testing.expect(problem(&wrong) != null);
}
