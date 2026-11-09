//! A plugin's published interface: what other plugins build against without its code, like
//! a `.d.ts`. Data only: the contracts it owns, each part's shapes as nodes, and its
//! dimensions with their wrappers. An installed plugin carries it in its manifest; a
//! compiled-in one has it from its declarations. `plugin build` hands each plugin on the
//! site to the plugin it builds as a module under that plugin's name (`@import("payments")`).
const std = @import("std");
const shapes = @import("contract.zig");
const dimension = @import("dimension.zig");

pub const contracts_max: u32 = 16;
pub const parts_max: u32 = 16;
pub const name_len_max: u32 = 64;

/// Whether a contract's providers bring a UI of their own.
pub const Component = enum { none, optional, required };

/// One part of a contract: what the owner sends its provider and what it reads back.
pub const Part = struct {
    name: []const u8,
    required: bool,
    input: []const shapes.Node,
    output: []const shapes.Node,
};

/// A contract a plugin owns, under its name: `payments.method`.
pub const Contract = struct {
    name: []const u8,
    parts: []const Part,
    component: Component = .none,

    pub fn part(contract: Contract, name: []const u8) ?Part {
        std.debug.assert(name.len > 0);
        std.debug.assert(contract.parts.len <= parts_max);

        for (contract.parts) |each| {
            if (std.mem.eql(u8, each.name, name)) {
                return each;
            }
        }

        return null;
    }
};

pub const Interface = struct {
    plugin: []const u8,
    version: []const u8,
    contracts: []const Contract = &.{},
    dimensions: []const dimension.Declared = &.{},

    pub fn contract(interface: Interface, name: []const u8) ?Contract {
        std.debug.assert(name.len > 0);
        std.debug.assert(interface.contracts.len <= contracts_max);

        for (interface.contracts) |each| {
            if (std.mem.eql(u8, each.name, name)) {
                return each;
            }
        }

        return null;
    }

    /// The field option `name`, when one of its dimensions offers it.
    pub fn field_option(interface: Interface, name: []const u8) ?dimension.FieldOption {
        std.debug.assert(name.len > 0);
        std.debug.assert(interface.dimensions.len <= dimension.dimensions_max);

        for (interface.dimensions) |each| {
            if (std.mem.eql(u8, each.field.name, name)) {
                return each.field;
            }
        }

        return null;
    }
};

/// Whether `name` sits under `plugin`: `payments.method` under `payments`.
pub fn owned_by(name: []const u8, plugin: []const u8) bool {
    std.debug.assert(plugin.len > 0);

    return name.len > plugin.len + 1 and std.mem.startsWith(u8, name, plugin) and
        name[plugin.len] == '.';
}

test "a contract's name sits under its plugin" {
    try std.testing.expect(owned_by("payments.method", "payments"));
    try std.testing.expect(!owned_by("payments", "payments"));
    try std.testing.expect(!owned_by("paymentsx.method", "payments"));
}
