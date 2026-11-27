//! A provider of a contract as Publr keeps it: compiled in, or carried in an installed
//! plugin's manifest. `publr.providers` answers them.
const std = @import("std");

pub const parts_max: u32 = 16;

/// One part a provider registered: the contract's part and the provider's operation for it.
pub const Part = struct {
    part: []const u8,
    operation: []const u8,
};

/// A provider as core keeps it: compiled in (`registry.providers`) or carried in an
/// installed plugin's manifest.
pub const Registered = struct {
    contract: []const u8,
    name: []const u8,
    /// What people see it as ("Bank transfer"); its name when empty.
    label: []const u8 = "",
    /// The plugin that registered it; set by core.
    plugin: []const u8 = "",
    parts: []const Part,
    /// The provider's component, when it brings one.
    component: []const u8 = "",
    /// The read drawing its piece on its owner's admin pages (a pickup point picker on the
    /// order that chose it), told the record (`record`, `base`, answering `html`); empty
    /// when it draws none.
    panel: []const u8 = "",
    /// What its contract's slot hands the component (the contract's `.with`), each field
    /// an attribute; empty when the contract leaves it open.
    with: []const @import("contract.zig").Node = &.{},
    /// The contract's part answered at install (`declare`), when it has one: its answer is
    /// kept as the provider's defaults.
    at_install: []const u8 = "",

    /// The provider's operation for `part`, when it has that part.
    pub fn operation_of(provider: Registered, part: []const u8) ?[]const u8 {
        std.debug.assert(part.len > 0);

        for (provider.parts) |each| {
            if (std.mem.eql(u8, each.part, part)) {
                return each.operation;
            }
        }

        return null;
    }

    /// Whether it has every part in `can`.
    pub fn has_all(provider: Registered, can: []const []const u8) bool {
        std.debug.assert(can.len <= parts_max);

        for (can) |part| {
            if (provider.operation_of(part) == null) {
                return false;
            }
        }

        return true;
    }
};
