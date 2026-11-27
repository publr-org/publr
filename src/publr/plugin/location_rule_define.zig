//! `.register_location_rules`: a location rule of the plugin's own (`loyalty.tier`), usable in
//! any `.location` and the Custom fields builder. `.values(ctx)` fills the admin's dropdown;
//! `.matches(ctx, target, rule)` decides for the account or file being edited, comparing with
//! core's operators through `rule.compare`. Read only and quick: no writes, no outside calls.
const std = @import("std");
const conditions = @import("../../model/conditions.zig");

pub const Target = @import("../model/field_group.zig").Target;

/// The rule as the group writes it: its operator and value.
pub const Rule = struct {
    operator: @import("../model/conditions.zig").Operator,
    value: []const u8,

    /// The target's own value against the rule, by its operator.
    pub fn compare(rule: Rule, actual: []const u8) bool {
        std.debug.assert(rule.value.len <= conditions.value_max);

        return conditions.match_rule(.{
            .field = "plugin",
            .operator = rule.operator,
            .value = rule.value,
        }, if (actual.len == 0) null else .{
            .string = actual,
        });
    }
};
