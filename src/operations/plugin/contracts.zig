//! The contracts between installed plugins, checked whenever one changes: enabling a
//! plugin checks what it uses; updating one checks it and every enabled plugin that needs
//! it. A required contract that does not fit refuses the change; an optional one leaves
//! the hook inert (see `plugin get`).

const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const store = @import("../../store.zig");
const registry = @import("../../server/registry.zig");
const state = @import("state.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;
const Manifest = model.sandboxed_plugin.Manifest;
const fit = model.plugin_contracts;

/// What is there now: every compiled-in plugin and every enabled installed one, with
/// `replacing` standing in for the installed plugin of its name (an update about to land).
pub fn providers(ctx: *Ctx, replacing: ?*const Manifest) Error![]const fit.Provider {
    std.debug.assert(ctx.now_ms >= 0);
    var list: std.ArrayList(fit.Provider) = .empty;
    const natives = registry.native_providers(ctx.arena) catch return error.OutOfMemory;

    std.debug.assert(natives.len <= 64);

    list.appendSlice(ctx.arena, natives) catch return error.OutOfMemory;

    for (try installed(ctx)) |manifest| {
        const stands_in = replacing != null and std.mem.eql(u8, replacing.?.name, manifest.name);

        if (!stands_in) {
            try append(ctx, &list, &manifest);
        }
    }

    if (replacing) |manifest| {
        try append(ctx, &list, manifest);
    }

    return list.items;
}

/// Refused, naming the contract, when one the plugin needs does not fit what is there.
pub fn check_user(ctx: *Ctx, manifest: *const Manifest, there: []const fit.Provider) Error!void {
    std.debug.assert(manifest.name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    var found: [fit.findings_max]fit.Finding = undefined;
    const count = fit.check(user_of(manifest), there, &found);

    for (found[0..count]) |finding| {
        if (finding.required) {
            var buffer: [256]u8 = undefined;
            const why = fit.describe(finding, &buffer);
            const message = std.fmt.allocPrint(ctx.arena, "{s} needs {s}", .{
                manifest.name,
                why,
            }) catch return error.OutOfMemory;

            return ctx.fail(.{ .name = "ContractMismatch", .status = 409, .message = message });
        }
    }
}

/// An update of `replacing` checked both ways: what it uses, and every enabled installed
/// plugin that needs it.
pub fn check_update(ctx: *Ctx, replacing: *const Manifest) Error!void {
    std.debug.assert(replacing.name.len > 0);

    const there = try providers(ctx, replacing);

    try check_user(ctx, replacing, there);

    for (try installed(ctx)) |manifest| {
        if (!std.mem.eql(u8, manifest.name, replacing.name)) {
            try check_user(ctx, &manifest, there);
        }
    }
}

/// Each contract of the plugin that does not fit what is there, in words: what `plugin get`
/// shows.
pub fn findings(ctx: *Ctx, manifest: *const Manifest) Error![]const []const u8 {
    std.debug.assert(manifest.name.len > 0);

    const there = try providers(ctx, null);
    var found: [fit.findings_max]fit.Finding = undefined;
    const count = fit.check(user_of(manifest), there, &found);
    const lines = ctx.arena.alloc([]const u8, count) catch return error.OutOfMemory;

    for (found[0..count], lines) |finding, *line| {
        var buffer: [256]u8 = undefined;
        const text = fit.describe(finding, &buffer);
        const kept = ctx.arena.dupe(u8, text) catch return error.OutOfMemory;

        line.* = if (finding.required) kept else std.fmt.allocPrint(
            ctx.arena,
            "{s} (optional: its hook is off)",
            .{kept},
        ) catch return error.OutOfMemory;
    }

    return lines;
}

pub fn user_of(manifest: *const Manifest) fit.User {
    return model.sandboxed_plugin.contract_user(manifest);
}

fn append(ctx: *Ctx, list: *std.ArrayList(fit.Provider), manifest: *const Manifest) Error!void {
    std.debug.assert(manifest.name.len > 0);

    const provider = model.sandboxed_plugin.contract_provider(ctx.arena, manifest) catch {
        return error.OutOfMemory;
    };

    list.append(ctx.arena, provider) catch return error.OutOfMemory;
}

/// The manifests of the enabled installed plugins.
fn installed(ctx: *Ctx) Error![]const Manifest {
    std.debug.assert(ctx.now_ms >= 0);

    const rows = try store.sandboxed_plugins.list(ctx.db, ctx.arena);
    var manifests: std.ArrayList(Manifest) = .empty;

    for (rows) |row| {
        if (row.enabled) {
            const manifest = try state.parse_manifest(ctx.arena, row.manifest);

            manifests.append(ctx.arena, manifest) catch return error.OutOfMemory;
        }
    }

    return manifests.items;
}

const contract = model.contract;

const Reserve = struct { sku: []const u8, quantity: u32 };

fn test_manifest(
    comptime Sends: type,
    depends: []const []const u8,
    works: []const []const u8,
) Manifest {
    std.debug.assert(depends.len + works.len > 0);

    return .{
        .format = model.sandboxed_plugin.format,
        .name = "cart",
        .version = "0.1.0",
        .summary = "Uses inventory",
        .depends_on = depends,
        .compatible_with = works,
        .remotes = &.{.{
            .operation = "app.inventory.reserve",
            .input = comptime contract.describe(Sends),
            .output = comptime contract.describe(struct { held: bool }),
        }},
    };
}

test "contracts: a required misfit refuses, an optional one does not" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const there = [_]fit.Provider{.{
        .plugin = "inventory",
        .version = "1.4.0",
        .operations = &.{.{
            .name = "app.inventory.reserve",
            .input = comptime contract.describe(Reserve),
            .output = comptime contract.describe(struct { held: bool, left: u32 }),
        }},
    }};

    const fits = test_manifest(Reserve, &.{"inventory@^1"}, &.{});
    try check_user(&ctx, &fits, &there);

    const required = test_manifest(struct { sku: []const u8 }, &.{"inventory@^1"}, &.{});
    try std.testing.expectError(error.Failed, check_user(&ctx, &required, &there));

    const optional = test_manifest(struct { sku: []const u8 }, &.{}, &.{"inventory"});
    try check_user(&ctx, &optional, &there);

    const too_new = test_manifest(Reserve, &.{"inventory@^2"}, &.{});
    try std.testing.expectError(error.Failed, check_user(&ctx, &too_new, &there));
}
