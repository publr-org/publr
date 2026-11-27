//! What the core looks up in a registry's lists at compile time, built once per registry:
//! an operation's position and owner by its name, a hook's owner by its position, the hooks
//! on an operation, the hooks of each stage, whether a namespace is documented. A lookup costs
//! the same however long the lists grow; nothing walks a list per call site.
const std = @import("std");
const sdk = @import("../sdk.zig");

/// Branches building a table takes for each item it holds, at most.
const branches_per_item: u32 = 64;

/// A struct whose comptime fields are `values` under `names` (unique): what a lookup by
/// name reads with `@hasField` and `@field`, never walking a list.
pub fn Table(
    comptime names: []const []const u8,
    comptime Value: type,
    comptime values: []const Value,
) type {
    comptime {
        std.debug.assert(names.len == values.len);

        @setEvalBranchQuota(1000 + names.len * branches_per_item);

        var types: [names.len]type = undefined;
        var attributes: [names.len]std.builtin.Type.Struct.FieldAttributes = undefined;

        for (values, &types, &attributes) |*value, *field_type, *attribute| {
            field_type.* = Value;
            attribute.* = .{
                .@"comptime" = true,
                .default_value_ptr = value,
            };
        }

        const done_names = names[0..names.len].*;
        const done_types = types;
        const done_attributes = attributes;

        return @Struct(.auto, null, &done_names, &done_types, &done_attributes);
    }
}

/// The value `name` holds in a `Table`, or null when it holds none.
pub fn get(comptime Built: type, comptime Value: type, comptime name: []const u8) ?Value {
    comptime {
        std.debug.assert(name.len > 0);

        if (!@hasField(Built, name)) {
            return null;
        }

        const table: Built = .{};

        return @field(table, name);
    }
}

pub fn Tables(comptime registry: sdk.Registry) type {
    return struct {
        const operations = registry.operations;
        const hooks = registry.hooks;

        /// Every operation's position under its name.
        const Positions = positions: {
            @setEvalBranchQuota(1000 + operations.len * branches_per_item);

            var names: [operations.len][]const u8 = undefined;
            var at: [operations.len]u32 = undefined;

            for (operations, &names, &at, 0..) |Operation, *name, *position, index| {
                name.* = Operation.name;
                position.* = index;
            }

            const done_names = names;
            const done_at = at;

            break :positions Table(&done_names, u32, &done_at);
        };

        /// Every documented namespace under its name.
        const Namespaces = namespaces: {
            @setEvalBranchQuota(1000 + registry.namespaces.len * branches_per_item);

            var names: [registry.namespaces.len][]const u8 = undefined;

            for (registry.namespaces, &names) |namespace, *name| {
                name.* = namespace.name;
            }

            const done_names = names;
            const truths: [done_names.len]bool = @splat(true);

            break :namespaces Table(&done_names, bool, &truths);
        };

        /// Whether the registry documents the namespace `name`.
        pub fn documented(comptime name: []const u8) bool {
            return comptime @hasField(Namespaces, name);
        }

        /// The position of the operation named `name`; null when none is registered.
        pub fn operation_position(comptime name: []const u8) ?u32 {
            return comptime get(Positions, u32, name);
        }

        /// The plugin the operation `name` belongs to; empty for the core's, or when the
        /// registry names no owners.
        pub fn operation_owner(comptime name: []const u8) []const u8 {
            comptime {
                if (registry.operation_owners.len == 0) {
                    return "";
                }

                const position = operation_position(name) orelse
                    @compileError("operation not registered: " ++ name);

                return registry.operation_owners[position];
            }
        }

        /// The plugin the hook at `index` belongs to; empty for the core's.
        pub fn hook_owner(comptime index: u32) []const u8 {
            comptime {
                std.debug.assert(index < hooks.len);

                if (registry.hook_owners.len == 0) {
                    return "";
                }

                return registry.hook_owners[index];
            }
        }

        /// The `before` and `after` hooks naming each operation, by position in its list,
        /// in their registry order.
        const on_operation: [operations.len][]const u32 = on: {
            @setEvalBranchQuota(1000 + (operations.len + hooks.len) * branches_per_item);

            var lists: [operations.len][]const u32 = @splat(&.{});

            for (hooks, 0..) |Middleware, index| {
                // A hook on an event named like an operation hears it where it is emitted.
                const staged = (Middleware.stage == .before or Middleware.stage == .after) and
                    !@hasDecl(Middleware, "event");

                if (staged) {
                    if (operation_position(Middleware.operation)) |position| {
                        lists[position] = lists[position] ++ .{index};
                    }
                }
            }

            break :on lists;
        };

        /// The positions of the `before` and `after` hooks naming the registered operation
        /// `name`, as `sdk.hooks.applies` decides, in registry order.
        pub fn hooks_on(comptime name: []const u8) []const u32 {
            comptime {
                const position = operation_position(name) orelse
                    @compileError("operation not registered: " ++ name);

                return on_operation[position];
            }
        }

        /// The positions of the hooks `keep` takes, in registry order.
        pub fn hooks_where(comptime keep: anytype) []const u32 {
            comptime {
                std.debug.assert(hooks.len <= sdk.hooks.hooks_max);

                @setEvalBranchQuota(1000 + hooks.len * branches_per_item);

                var kept: []const u32 = &.{};

                for (hooks, 0..) |Middleware, index| {
                    if (keep(Middleware)) {
                        kept = kept ++ .{index};
                    }
                }

                return kept;
            }
        }

        /// Every plugin owning a compiled-in operation, and every namespace of the core's:
        /// what a hook's target is checked against.
        const Present = present: {
            // Operations come grouped by plugin: a name is looked for among the few listed.
            @setEvalBranchQuota(1000 + operations.len * branches_per_item * 64);

            var names: []const []const u8 = &.{};

            if (registry.operation_owners.len > 0) {
                for (operations, registry.operation_owners) |Operation, owner| {
                    const name = if (owner.len == 0)
                        sdk.operation.namespace(Operation.name)
                    else
                        owner;

                    // Each operation's owner follows its plugin's others: compare the last.
                    if (names.len == 0 or !std.mem.eql(u8, names[names.len - 1], name)) {
                        if (!listed(names, name)) {
                            names = names ++ .{name};
                        }
                    }
                }
            }

            const done = names;
            const truths: [done.len]bool = @splat(true);

            break :present Table(done, bool, &truths);
        };

        fn listed(comptime names: []const []const u8, comptime name: []const u8) bool {
            comptime {
                std.debug.assert(name.len > 0);

                for (names) |each| {
                    if (std.mem.eql(u8, each, name)) {
                        return true;
                    }
                }

                return false;
            }
        }

        /// Whether a compiled-in plugin, or the core's namespace, is named `name`.
        pub fn present(comptime name: []const u8) bool {
            return comptime @hasField(Present, name);
        }
    };
}
