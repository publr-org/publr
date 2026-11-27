const std = @import("std");
const sdk = @import("../../sdk.zig");
const public = @import("../../publr/operations/identity/providers.zig");
const registry = @import("../../server/registry.zig");
const secret = @import("../secret.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;

pub const Offered = public.Offered;

pub const Providers = struct {
    pub const shape = public.Providers;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

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
