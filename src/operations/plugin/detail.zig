//! What the plugin operations answer: a plugin as the list shows it, and with everything
//! its page shows. Their documented examples live here too, each as the parity world
//! leaves it: `greeter` enabled, rolled back from 0.2.0, with 0.2.0 offered again; `farewell`
//! added and disabled.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const state = @import("state.zig");
const versions = @import("versions.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const permission = model.permission;
const Request = state.Request;
const ContentAccess = state.ContentAccess;

/// How a plugin is loaded: `native`, built into this binary, or `sandboxed`, installed and run
/// in the sandbox.
pub const Mode = @import("../../sdk/plugin/context.zig").Mode;

/// A plugin as the list shows it, built-in or installed.
pub const Summary = struct {
    name: []const u8,
    version: []const u8,
    summary: []const u8,
    mode: Mode,
    /// Always, for a native plugin.
    enabled: bool,
    /// How many requests wait for an administrator.
    pending: u32,
    /// The version of a newer module waiting to be applied.
    update: ?[]const u8,
};

/// A plugin with everything its page shows.
pub const Detail = struct {
    name: []const u8,
    version: []const u8,
    summary: []const u8,
    hash: []const u8,
    enabled: bool,
    /// Every request and where it stands; for a plugin disabled, where enabling it
    /// would leave it.
    requests: []const Request,
    content_access: ContentAccess,
    recommend: model.sandboxed_plugin.ContentAccess,
    /// Whether it asks for any content permission: the content access choice applies.
    uses_content: bool,
    allowed_domains: []const []const u8,
    operations: []const []const u8,
    /// A newer version waiting, and where its requests would stand once applied.
    update: ?Next = null,
    /// The version the last update replaced, to roll back to.
    previous: ?[]const u8 = null,

    pub const Next = struct { version: []const u8, requests: []const Request };
};

const example_hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

pub const example_request: Request = .{
    .key = "users.names",
    .sentence = "See the names of people on your site",
    .reason = "Greets the people on the site by name",
    .tier = .low,
    .state = .granted,
};

const example_next: Detail.Next = .{ .version = "0.2.0", .requests = &.{.{
    .key = "users.read",
    .sentence = "Access user accounts and email addresses",
    .reason = "Greets people by their email address too",
    .tier = .high,
    .state = .granted,
}} };

/// `greeter` as it runs: enabled, 0.2.0 offered, 0.2.0 behind it to roll back to.
pub const example_detail: Detail = .{
    .name = "greeter",
    .version = "0.1.0",
    .summary = "Greetings kept as records",
    .hash = example_hash,
    .enabled = true,
    .requests = &.{example_request},
    .content_access = .{},
    .recommend = .{},
    .uses_content = false,
    .allowed_domains = &.{},
    .operations = &.{ "greeter.greet", "greeter.count", "greeter.people" },
    .update = example_next,
    .previous = "0.2.0",
};

const no_update: ?Detail.Next = null;

pub const example_updated: Detail = with(.{
    .version = "0.2.0",
    .update = no_update,
    .previous = "0.1.0",
});
pub const example_cancelled: Detail = with(.{ .update = no_update });
pub const example_rolled_back: Detail = with(.{ .version = "0.2.0", .previous = "0.1.0" });
pub const example_disabled: Detail = with(.{ .enabled = false });

pub const example_enabled: Detail = .{
    .name = "farewell",
    .version = "0.1.0",
    .summary = "Says goodbye",
    .hash = example_hash,
    .enabled = true,
    .requests = &.{},
    .content_access = .{},
    .recommend = .{},
    .uses_content = false,
    .allowed_domains = &.{},
    .operations = &.{"farewell.say"},
};

const Changes = struct {
    version: ?[]const u8 = null,
    enabled: ?bool = null,
    update: ??Detail.Next = null,
    previous: ??[]const u8 = null,
};

fn with(changes: Changes) Detail {
    std.debug.assert(example_detail.name.len > 0);
    std.debug.assert(example_detail.enabled);

    var detail = example_detail;

    if (changes.version) |version| {
        detail.version = version;
    }

    if (changes.enabled) |enabled| {
        detail.enabled = enabled;
    }

    if (changes.update) |update| {
        detail.update = update;
    }

    if (changes.previous) |previous| {
        detail.previous = previous;
    }

    return detail;
}

pub fn summary_of(arena: std.mem.Allocator, decoded: state.Decoded) Error!Summary {
    std.debug.assert(decoded.row.name.len > 0);

    const shown = try shown_requests(arena, decoded);
    var pending: u32 = 0;

    for (shown) |request| {
        pending += @intFromBool(request.state == .pending);
    }

    return .{
        .name = decoded.row.name,
        .version = decoded.row.version,
        .summary = decoded.manifest.summary,
        .mode = .sandboxed,
        .enabled = decoded.row.enabled,
        .pending = pending,
        .update = decoded.row.next_version,
    };
}

/// Its requests as they stand, or (disabled) as enabling it would leave them.
fn shown_requests(arena: std.mem.Allocator, decoded: state.Decoded) Error![]const Request {
    std.debug.assert(decoded.manifest.name.len > 0);

    var granted = decoded.granted;

    if (!decoded.row.enabled) {
        const manifest = &decoded.manifest;
        const asked = model.sandboxed_plugin.requests(&permission.core, manifest, arena) catch {
            return error.Invalid;
        };

        granted = try versions.carried(arena, asked, decoded.granted, decoded.denied, false);
    }

    return state.requests_of(arena, &decoded.manifest, granted, decoded.denied);
}

pub fn detail_of(ctx: *Ctx, decoded: state.Decoded) Error!Detail {
    std.debug.assert(decoded.row.name.len > 0);

    const manifest = &decoded.manifest;
    const names = try ctx.arena.alloc([]const u8, manifest.operations.len);
    var uses_content = false;

    for (manifest.operations, names) |operation, *name| {
        name.* = operation.name;
    }

    for (manifest.permissions) |ask| {
        const found = permission.find(&permission.core, ask.key) orelse continue;

        uses_content = uses_content or found.content;
    }

    return .{
        .name = manifest.name,
        .version = manifest.version,
        .summary = manifest.summary,
        .hash = decoded.row.hash,
        .enabled = decoded.row.enabled,
        .requests = try shown_requests(ctx.arena, decoded),
        .content_access = decoded.content_access,
        .recommend = manifest.content_access,
        .uses_content = uses_content,
        .allowed_domains = manifest.allowed_domains,
        .operations = names,
        .update = try next_of(ctx, decoded),
        .previous = decoded.row.previous_version,
    };
}

/// The next version's requests as applying it would leave them: everything it asks for
/// that something installed provides, granted.
fn next_of(ctx: *Ctx, decoded: state.Decoded) Error!?Detail.Next {
    std.debug.assert(decoded.row.name.len > 0);

    const text = decoded.row.next_manifest orelse return null;
    const next = try state.parse_manifest(ctx.arena, text);
    const asked = model.sandboxed_plugin.requests(&permission.core, &next, ctx.arena) catch {
        return error.Invalid;
    };
    const granted = try versions.carried(ctx.arena, asked, decoded.granted, decoded.denied, true);

    return .{
        .version = next.version,
        .requests = try state.requests_of(ctx.arena, &next, granted, decoded.denied),
    };
}
