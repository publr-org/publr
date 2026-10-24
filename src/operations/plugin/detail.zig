//! What the plugin operations answer: a plugin as the list shows it, and with everything
//! its page shows. Their documented examples live here too, each as the parity world
//! leaves it: `greeter` enabled, rolled back from 0.2.0, with 0.2.0 offered again; `farewell`
//! added and disabled.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const state = @import("state.zig");
const versions = @import("versions.zig");
const contracts = @import("contracts.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const permission = model.permission;
const Request = state.Request;

/// How a plugin is loaded: `native`, built into this binary, or `sandboxed`, installed and run
/// in the sandbox.
pub const Mode = state.Mode;

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
    /// `native` for a built-in plugin: always enabled, every request granted, nothing to
    /// review, update, roll back or remove.
    mode: Mode = .sandboxed,
    hash: []const u8,
    enabled: bool,
    /// Every request and where it stands; for a plugin disabled, where enabling it
    /// would leave it.
    requests: []const Request,
    operations: []const []const u8,
    /// A newer version waiting, and where its requests would stand once applied.
    update: ?Next = null,
    /// The version the last update replaced, to roll back to.
    previous: ?[]const u8 = null,
    /// What the plugin brings that its sandboxed build left out, each with why.
    left_out: []const []const u8 = &.{},
    /// What the plugin checks warned of, each `file:line: why`: never a stop.
    warnings: []const []const u8 = &.{},
    /// Why it can't be enabled: each remote it needs (`depends_on`) that does not fit what
    /// is there now, in plain words.
    blocked: []const []const u8 = &.{},
    /// Each remote it works with (`compatible_with`) that is off, and why: calls to it
    /// answer `Unavailable` and its hooks don't run until it fits.
    off: []const contracts.Off = &.{},
    /// The secrets it declares: shown under its `http.fetch` request, never their values.
    secrets: []const Secret = &.{},

    /// A secret the plugin declares, and whether it has a value; never the value.
    pub const Secret = struct {
        name: []const u8,
        label: []const u8,
        /// Where to find it, as the plugin says.
        help: []const u8 = "",
        set: bool = false,
        /// The other plugins that declare the same name and so share its value.
        shared_with: []const []const u8 = &.{},
    };

    pub const Next = struct {
        version: []const u8,
        requests: []const Request,
        /// The enabled plugins that need this plugin as it is now, each with why: applying
        /// the update is refused until they are updated or removed.
        stops: []const []const u8 = &.{},
        /// The remotes of other plugins it would switch off, each with why.
        switches_off: []const []const u8 = &.{},
    };
};

const example_hash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";

pub const example_request: Request = .{
    .key = "users.names",
    .sentence = "See the names of people on your site",
    .reason = "Greets the people on the site by name",
    .tier = .low,
    .state = .granted,
};

const example_next: Detail.Next = .{
    .version = "0.2.0",
    .requests = &.{.{
        .key = "users.read",
        .sentence = "Access user accounts and email addresses",
        .reason = "Greets people by their email address too",
        .tier = .high,
        .state = .granted,
    }},
};

/// `greeter` as it runs: enabled, 0.2.0 offered, 0.2.0 behind it to roll back to.
pub const example_detail: Detail = .{
    .name = "greeter",
    .version = "0.1.0",
    .summary = "Greetings kept as records",
    .hash = example_hash,
    .enabled = true,
    .requests = &.{example_request},
    .operations = &.{ "greeter.greet", "greeter.count", "greeter.people" },
    .update = example_next,
    .previous = "0.2.0",
    .off = &.{.{
        .name = "sampler.hello",
        .why = "sampler isn't installed or enabled",
    }},
};

const no_update: ?Detail.Next = null;

pub const example_updated: Detail = with(.{
    .version = "0.2.0",
    .update = no_update,
    .previous = "0.1.0",
    .off = &.{},
});
pub const example_cancelled: Detail = with(.{
    .update = no_update,
});
pub const example_rolled_back: Detail = with(.{
    .version = "0.2.0",
    .previous = "0.1.0",
    .off = &.{},
});
pub const example_disabled: Detail = with(.{
    .enabled = false,
});

pub const example_enabled: Detail = .{
    .name = "farewell",
    .version = "0.1.0",
    .summary = "Says goodbye",
    .hash = example_hash,
    .enabled = true,
    .requests = &.{},
    .operations = &.{"farewell.say"},
};

const Changes = struct {
    version: ?[]const u8 = null,
    enabled: ?bool = null,
    update: ??Detail.Next = null,
    previous: ??[]const u8 = null,
    off: ?[]const contracts.Off = null,
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

    if (changes.off) |off| {
        detail.off = off;
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
        const asked = model.sandboxed_plugin.requests(manifest, arena) catch {
            return error.Invalid;
        };

        granted = try versions.carried(arena, asked, decoded.granted, decoded.denied, false);
    }

    return state.requests_of(arena, &decoded.manifest, granted, decoded.denied, decoded.grants);
}

pub fn detail_of(ctx: *Ctx, decoded: state.Decoded) Error!Detail {
    std.debug.assert(decoded.row.name.len > 0);

    const manifest = &decoded.manifest;
    const names = try ctx.arena.alloc([]const u8, manifest.operations.len);

    for (manifest.operations, names) |operation, *name| {
        name.* = operation.name;
    }

    const remotes = try contracts.standing(ctx, manifest);

    return .{
        .name = manifest.name,
        .version = manifest.version,
        .summary = manifest.summary,
        .mode = decoded.mode,
        .hash = decoded.row.hash,
        .enabled = decoded.row.enabled,
        .requests = try shown_requests(ctx.arena, decoded),
        .operations = names,
        .update = try next_of(ctx, decoded),
        .previous = decoded.row.previous_version,
        .left_out = manifest.left_out,
        .warnings = try warnings_of(ctx, manifest),
        .blocked = remotes.blocked,
        .off = remotes.off,
        .secrets = try secrets_of(ctx, manifest),
    };
}

/// What its checks warned of, then each type its taxonomies wait for although the type's
/// plugin is here.
fn warnings_of(
    ctx: *Ctx,
    manifest: *const model.sandboxed_plugin.Manifest,
) Error![]const []const u8 {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(manifest.warnings.len <= 1 << 16);

    const waiting = try @import("../taxonomy/on_type.zig").missing_types(ctx, manifest.name);

    if (waiting.len == 0) {
        return manifest.warnings;
    }

    return std.mem.concat(ctx.arena, []const u8, &.{ manifest.warnings, waiting }) catch
        error.OutOfMemory;
}

/// The secrets `manifest` declares, each with whether it is set and who else uses it.
fn secrets_of(
    ctx: *Ctx,
    manifest: *const model.sandboxed_plugin.Manifest,
) Error![]const Detail.Secret {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(manifest.secrets.len <= model.secrets.declared_max);

    const secret = @import("../secret.zig");
    const shown = try ctx.arena.alloc(Detail.Secret, manifest.secrets.len);

    for (manifest.secrets, shown) |declared, *one| {
        one.* = .{
            .name = declared.name,
            .label = declared.label,
            .help = declared.help,
            .set = try secret.is_set(ctx, declared.name),
            .shared_with = try secret.users_of(ctx, declared.name, manifest.name),
        };
    }

    return shown;
}

/// The next version's requests as applying it would leave them: everything it asks for
/// that something installed provides, granted.
fn next_of(ctx: *Ctx, decoded: state.Decoded) Error!?Detail.Next {
    std.debug.assert(decoded.row.name.len > 0);

    const text = decoded.row.next_manifest orelse return null;
    const next = try state.parse_manifest(ctx.arena, text);
    const asked = model.sandboxed_plugin.requests(&next, ctx.arena) catch {
        return error.Invalid;
    };
    const granted = try versions.carried(ctx.arena, asked, decoded.granted, decoded.denied, true);
    const effects = try contracts.update_effects(ctx, &next);
    const sandboxed_plugin = model.sandboxed_plugin;
    const grants = try sandboxed_plugin.grants_after(
        ctx.arena,
        decoded.grants,
        &decoded.manifest,
        &next,
        true,
    );
    const requests = try ctx.arena.dupe(
        state.Request,
        try state.requests_of(ctx.arena, &next, granted, decoded.denied, grants),
    );

    for (requests) |*request| {
        if (permission.find(request.key)) |entry| {
            if (entry.narrowing == .domains) {
                request.new_domains = try sandboxed_plugin.added_domains(
                    ctx.arena,
                    &decoded.manifest,
                    &next,
                    request.key,
                );
            }
        }
    }

    return .{
        .version = next.version,
        .stops = effects.stops,
        .switches_off = effects.switches_off,
        .requests = requests,
    };
}
