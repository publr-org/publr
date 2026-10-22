//! `.register_location_rules`: a location rule of the plugin's own (`loyalty.tier`), usable in
//! any `.location` and the Custom fields builder. `.values(ctx)` fills the admin's dropdown;
//! `.matches(ctx, target, rule)` decides for the account or file being edited, comparing with
//! core's operators through `rule.compare`. Read only and quick: no writes, no outside calls.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const field_group = @import("../../model/field_group.zig");
const conditions = @import("../../model/conditions.zig");
const plugin_context = @import("context.zig");

pub const Target = field_group.Target;

/// The rule as the group writes it: its operator and value.
pub const Rule = struct {
    operator: conditions.Operator,
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

/// The plugin's rules, each named under it.
pub fn rules_of(comptime Plugin: type) []const field_group.PluginRule {
    comptime {
        const plugin = Plugin.manifest.name;
        var list: []const field_group.PluginRule = &.{};

        std.debug.assert(plugin.len > 0);

        // A plugin made by hand (tests) carries no `define` options.
        const options_given = @hasDecl(Plugin, "options");

        if (!options_given or !@hasField(@TypeOf(Plugin.options), "register_location_rules")) {
            return list;
        }

        for (Plugin.options.register_location_rules) |given| {
            const Run = Ran(plugin, given);

            list = list ++ [_]field_group.PluginRule{.{
                .id = plugin ++ "." ++ given.name,
                .label = given.label,
                .values = Run.values,
                .matches = Run.matches,
            }};
        }

        const done = list;

        return done;
    }
}

/// The plugin's functions run as the plugin, with the caller's ctx.
fn Ran(comptime plugin: []const u8, comptime given: anytype) type {
    return struct {
        fn values(ctx: *anyopaque) []const []const u8 {
            const inner: *sdk.Ctx = @ptrCast(@alignCast(ctx));
            const running = inner.plugin;
            var wrapped: plugin_context.PluginCtx = .{
                .inner = inner,
            };

            std.debug.assert(plugin.len > 0);
            inner.plugin = plugin;
            defer inner.plugin = running;

            return given.values(&wrapped) catch &.{};
        }

        fn matches(ctx: *anyopaque, target: Target, rule: conditions.Rule) bool {
            const inner: *sdk.Ctx = @ptrCast(@alignCast(ctx));
            const running = inner.plugin;
            var wrapped: plugin_context.PluginCtx = .{
                .inner = inner,
            };

            std.debug.assert(target.id.len > 0);
            inner.plugin = plugin;
            defer inner.plugin = running;

            return given.matches(&wrapped, target, .{
                .operator = rule.operator,
                .value = rule.value,
            }) catch false;
        }
    };
}
