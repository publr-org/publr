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
const public = @import("../../publr/operations/plugin/detail.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const permission = model.permission;
const Request = state.Request;

pub const Mode = public.Mode;
pub const Summary = public.Summary;
pub const Detail = public.Detail;
pub const example_request = public.example_request;
pub const example_detail = public.example_detail;
pub const example_updated = public.example_updated;
pub const example_cancelled = public.example_cancelled;
pub const example_rolled_back = public.example_rolled_back;
pub const example_disabled = public.example_disabled;
pub const example_enabled = public.example_enabled;

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

    return detail_among(ctx, decoded, try contracts.providers(ctx, .{}));
}

/// `detail_of` against what is there, read once by a caller showing several plugins.
pub fn detail_among(
    ctx: *Ctx,
    decoded: state.Decoded,
    there: []const contracts.Provider,
) Error!Detail {
    std.debug.assert(decoded.row.name.len > 0);
    std.debug.assert(there.len <= 1 << 16);

    const manifest = &decoded.manifest;
    const names = try ctx.arena.alloc([]const u8, manifest.operations.len);

    for (manifest.operations, names) |operation, *name| {
        name.* = operation.name;
    }

    const remotes = try contracts.standing_among(ctx, manifest, there);

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
    const staff = try staff_types(ctx, manifest);

    if (waiting.len == 0 and staff.len == 0) {
        return manifest.warnings;
    }

    return std.mem.concat(ctx.arena, []const u8, &.{ manifest.warnings, waiting, staff }) catch
        error.OutOfMemory;
}

/// Each type it registers that names a role staff now, which so gives nothing.
fn staff_types(
    ctx: *Ctx,
    manifest: *const model.sandboxed_plugin.Manifest,
) Error![]const []const u8 {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(manifest.user_types.len <= model.user_type.types_max);

    var said: std.ArrayList([]const u8) = .empty;

    for (manifest.user_types) |declared| {
        const user_types = @import("../../sdk/user_types.zig");
        const given = try user_types.staff_role_given(ctx, declared) orelse continue;
        const text = std.fmt.allocPrint(ctx.arena, "Its type {s} gives nothing: the role {s} " ++
            "reaches what staff call, and a type gives member roles only", .{
            declared.label,
            given,
        }) catch return error.OutOfMemory;

        said.append(ctx.arena, text) catch return error.OutOfMemory;
    }

    return said.items;
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
