//! The site an example runs on: its plugin, the plugins it depends on and those it works
//! with, all the way down. Another compiled-in plugin providing one of their contracts (a
//! country's tax law for `tax`) is switched off there, as an administrator switches a
//! provider off: an example says what its plugin answers, never what a plugin built on it
//! adds.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const depends_on = @import("../plugin/depends_on.zig");
const contract = @import("../contract.zig");
const SetProviders = @import("../../operations/provider.zig").Set;

/// Switches off, for `ctx`'s site, every provider of a plugin outside `plugin`'s site.
pub fn keep_to(comptime registry: type, ctx: *sdk.Ctx, plugin: []const u8) sdk.Error!void {
    std.debug.assert(plugin.len > 0);

    const grants = comptime registry.registry.plugin_grants orelse &.{};
    const providers = registry.providers;
    var storage: [grants.len + 1][]const u8 = undefined;
    const site = plugins_of(grants, plugin, &storage);

    std.debug.assert(site.len >= 1);

    for (providers, 0..) |provider, index| {
        if (listed_contract(providers[0..index], provider.contract)) {
            continue;
        }

        var off: [contract.providers_max][]const u8 = undefined;
        var count: u32 = 0;

        for (providers[index..]) |other| {
            const others = std.mem.eql(u8, other.contract, provider.contract) and
                !listed(site, other.plugin);

            if (others and count < off.len) {
                off[count] = other.name;
                count += 1;
            }
        }

        if (count > 0) {
            _ = try registry.SDK.dispatch(ctx, SetProviders, .{
                .contract = provider.contract,
                .off = off[0..count],
            });
        }
    }
}

/// `plugin` and every plugin it depends on or works with, directly or through others, each
/// once, as `grants` (the compiled-in plugins') name them.
pub fn plugins_of(
    grants: []const sdk.PluginGrants,
    plugin: []const u8,
    storage: [][]const u8,
) []const []const u8 {
    std.debug.assert(storage.len == grants.len + 1);
    std.debug.assert(plugin.len > 0);

    storage[0] = plugin;

    var count: u32 = 1;
    var next: u32 = 0;

    while (next < count) : (next += 1) {
        const access = access_of(grants, storage[next]) orelse continue;

        for ([_][]const []const u8{ access.depends_on, access.compatible_with }) |list| {
            for (list) |text| {
                const name = depends_on.parse(text).name;

                if (!listed(storage[0..count], name) and count < storage.len) {
                    storage[count] = name;
                    count += 1;
                }
            }
        }
    }

    return storage[0..count];
}

fn access_of(
    grants: []const sdk.PluginGrants,
    name: []const u8,
) ?*const @import("../plugin_access.zig").Access {
    std.debug.assert(name.len > 0);

    for (grants) |*each| {
        if (std.mem.eql(u8, each.name, name)) {
            return &each.access;
        }
    }

    return null;
}

fn listed(names: []const []const u8, name: []const u8) bool {
    std.debug.assert(names.len <= 1 << 10);

    for (names) |each| {
        if (std.mem.eql(u8, each, name)) {
            return true;
        }
    }

    return false;
}

fn listed_contract(providers: anytype, name: []const u8) bool {
    std.debug.assert(name.len > 0);

    for (providers) |provider| {
        if (std.mem.eql(u8, provider.contract, name)) {
            return true;
        }
    }

    return false;
}

test "a plugin's site holds what it depends on and works with, not what builds on it" {
    const grants = [_]sdk.PluginGrants{
        .{
            .name = "orders",
            .access = .{
                .own_types = &.{},
                .compatible_with = &.{"currencies@^0.1"},
            },
        },
        .{
            .name = "tax",
            .access = .{
                .own_types = &.{},
                .depends_on = &.{"orders@^0.3"},
            },
        },
        .{
            .name = "tax_pl",
            .access = .{
                .own_types = &.{},
                .depends_on = &.{"tax@^0.1"},
            },
        },
        .{
            .name = "currencies",
            .access = .{
                .own_types = &.{},
            },
        },
    };
    var storage: [grants.len + 1][]const u8 = undefined;
    const site = plugins_of(&grants, "tax", &storage);

    try std.testing.expectEqual(3, site.len);
    try std.testing.expect(listed(site, "orders"));
    try std.testing.expect(listed(site, "currencies"));
    try std.testing.expect(!listed(site, "tax_pl"));
}
