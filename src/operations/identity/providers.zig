//! Which providers a login page may offer: the ones compiled in whose credentials are there.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");
const secret = @import("../secret.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Offered = struct {
    name: []const u8,
    label: []const u8,
    icon: []const u8,
    /// Where "Continue with <label>" goes: `/auth/<name>`.
    path: []const u8,
};

pub const Providers = struct {
    pub const name = "identity.providers";
    pub const description = "The sign-in providers this site offers";
    pub const details =
        \\Anyone may call it: a login page asks it which buttons to show. A provider is
        \\offered when its plugin is compiled in, its client id is in the environment and every
        \\secret its plugin declares is set; one without them is left out, not broken.
        \\Nothing is written.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    /// A login page reads it while rendering; opening the page changes nothing.
    pub const allow_frontmatter_calls = true;
    pub const In = struct {};
    pub const Out = struct {
        providers: []const Offered,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .providers = &.{},
    };
    pub const field_docs: sdk.operation.Docs(In) = .{};
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .providers = "Each offered provider, in name order: `name` (`github`), `label` " ++
            "(`GitHub`), `icon` (an SVG path on a 24 by 24 canvas) and `path` " ++
            "(`/auth/github`); empty with no provider plugin",
    };

    pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);

        return .{
            .providers = try offered(ctx, registry.sign_in_providers),
        };
    }
};

/// The providers that are available now, as a login page lists them.
pub fn offered(ctx: *Ctx, providers: []const sdk.provider.SignInProvider) Error![]const Offered {
    std.debug.assert(providers.len <= sdk.provider.providers_max);

    const arena = ctx.arena;
    var list: std.ArrayList(Offered) = .empty;

    for (providers) |*provider| {
        if (!try available(ctx, provider)) {
            continue;
        }

        const path = std.fmt.allocPrint(arena, "/auth/{s}", .{provider.name}) catch {
            return error.OutOfMemory;
        };

        list.append(arena, .{
            .name = provider.name,
            .label = provider.label,
            .icon = provider.icon,
            .path = path,
        }) catch return error.OutOfMemory;
    }

    std.debug.assert(list.items.len <= providers.len);

    return list.items;
}

/// Its client id is there (`available`) and every secret its plugin declares is set.
pub fn available(ctx: *Ctx, provider: *const sdk.provider.SignInProvider) Error!bool {
    std.debug.assert(provider.name.len > 0);
    std.debug.assert(ctx.now_ms >= 0);

    if (!provider.available()) {
        return false;
    }

    const access = registry.SDK.compiled_access(provider.plugin) orelse return true;

    for (access.secrets) |declared| {
        if (!try secret.is_set(ctx, declared.name)) {
            return false;
        }
    }

    return true;
}

test "only providers with their credentials are offered" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var ctx = harness.ctx(.system);
    const declared = [_]sdk.provider.SignInProvider{
        sdk.provider.testing.trusting,
        sdk.provider.testing.missing,
    };
    const list = try offered(&ctx, &declared);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("trusting", list[0].name);
    try std.testing.expectEqualStrings("/auth/trusting", list[0].path);
}
