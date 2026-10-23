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

        for (given_of(Plugin)) |given| {
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

/// The plugin's `.register_location_rules` as written, empty when it gives none.
pub fn given_of(comptime Plugin: type) if (declares(Plugin))
    @TypeOf(Plugin.options.register_location_rules)
else
    @TypeOf(.{}) {
    return if (comptime declares(Plugin)) Plugin.options.register_location_rules else .{};
}

fn declares(comptime Plugin: type) bool {
    // A plugin made by hand (tests) carries no `define` options.
    return @hasDecl(Plugin, "options") and
        @hasField(@TypeOf(Plugin.options), "register_location_rules");
}

/// An installed plugin's rule, run in the sandbox by its name (`sampler.has_motto`): what
/// the host lists beside the compiled-in plugins' rules.
pub fn installed(id: []const u8, label: []const u8) field_group.PluginRule {
    std.debug.assert(std.mem.indexOfScalar(u8, id, '.') != null);

    return .{
        .id = id,
        .label = label,
        .values = installed_values,
        .matches = installed_matches,
    };
}

fn installed_values(ctx: *anyopaque, id: []const u8) []const []const u8 {
    const inner: *sdk.Ctx = @ptrCast(@alignCast(ctx));
    const sandboxed = inner.sandboxed_plugins orelse return &.{};
    const answered = sandboxed.extra(inner, .rule_values, id, "{}") catch return &.{};

    std.debug.assert(id.len > 0);

    return std.json.parseFromSliceLeaky([]const []const u8, inner.arena, answered, .{
        .allocate = .alloc_always,
    }) catch &.{};
}

fn installed_matches(ctx: *anyopaque, target: Target, rule: conditions.Rule) bool {
    const inner: *sdk.Ctx = @ptrCast(@alignCast(ctx));
    const sandboxed = inner.sandboxed_plugins orelse return false;
    const input = sdk.stringify(inner.arena, Asked{
        .target = target,
        .rule = .{
            .operator = rule.operator,
            .value = rule.value,
        },
    }) catch return false;
    const answered = sandboxed.extra(inner, .rule_matches, rule.field, input) catch return false;

    std.debug.assert(target.id.len > 0);

    return std.mem.eql(u8, answered, "true");
}

/// What an installed rule's `matches` is handed.
pub const Asked = struct {
    target: Target,
    rule: Rule,
};

/// The plugin's functions run as the plugin, with the caller's ctx.
fn Ran(comptime plugin: []const u8, comptime given: anytype) type {
    return struct {
        fn values(ctx: *anyopaque, id: []const u8) []const []const u8 {
            const inner: *sdk.Ctx = @ptrCast(@alignCast(ctx));
            const running = inner.plugin;
            var wrapped: plugin_context.PluginCtx = .{
                .inner = inner,
            };

            std.debug.assert(std.mem.startsWith(u8, id, plugin));
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
