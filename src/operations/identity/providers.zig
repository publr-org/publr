//! Which providers a login page may offer: the ones compiled in whose credentials are there.

const std = @import("std");
const sdk = @import("../../sdk.zig");
const registry = @import("../../server/registry.zig");

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
        \\offered when its plugin is compiled in and its credentials are in the environment;
        \\one without them is left out, not broken. Nothing is written.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const open = true;
    /// A login page reads it while rendering; opening the page changes nothing.
    pub const allow_frontmatter_calls = true;
    pub const In = struct {};
    pub const Out = struct { providers: []const Offered };
    pub const example: In = .{};
    pub const example_out: Out = .{ .providers = &.{} };
    pub const field_docs: sdk.operation.Docs(In) = .{};
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .providers = "Each offered provider, in name order: `name` (`github`), `label` " ++
            "(`GitHub`), `icon` (an SVG path on a 24 by 24 canvas) and `path` " ++
            "(`/auth/github`); empty with no provider plugin",
    };

    pub fn run(ctx: *Ctx, _: In, _: *const Grant) Error!Out {
        std.debug.assert(ctx.now_ms >= 0);

        return .{ .providers = try offered(ctx.arena, registry.sign_in_providers) };
    }
};

/// The providers that are available now, as a login page lists them.
pub fn offered(
    arena: std.mem.Allocator,
    providers: []const sdk.provider.SignInProvider,
) Error![]const Offered {
    std.debug.assert(providers.len <= sdk.provider.providers_max);

    var list: std.ArrayList(Offered) = .empty;

    for (providers) |provider| {
        if (!provider.available()) {
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

test "only providers with their credentials are offered" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();

    const declared = [_]sdk.provider.SignInProvider{
        sdk.provider.testing.trusting,
        sdk.provider.testing.missing,
    };
    const list = try offered(arena_state.allocator(), &declared);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("trusting", list[0].name);
    try std.testing.expectEqualStrings("/auth/trusting", list[0].path);
}
