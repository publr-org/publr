//! What a plugin declares to run in the sandbox, on top of what every plugin declares: the
//! permissions it asks for and why, the domains it fetches from, the limits it needs, the
//! plugins it cannot work without. `manifest.zig` turns all of it into the manifest.
const std = @import("std");
const sdk_operation = @import("../operation.zig");
const middleware = @import("../middleware.zig");

pub const permissions_max: u32 = 64;
pub const domains_max: u32 = 32;
pub const requires_max: u32 = 16;
pub const reason_len_max: u32 = 200;
pub const entries_max: u32 = 256;

const sandboxed_plugin = @import("../../model/sandboxed_plugin.zig");
const catalog = @import("../../model/permission.zig");

/// A permission a plugin asks for, by the key the administrator sees (`content.write`), and
/// the plugin's own sentence on why it needs it.
pub const Permission = sandboxed_plugin.Ask;
/// More than the defaults, asked for with a reason; each raised limit waits for approval.
pub const Limits = sandboxed_plugin.Limits;
/// Which content the plugin recommends it be given; the administrator decides.
pub const ContentAccess = sandboxed_plugin.ContentAccess;

/// One thing the host can run in a plugin's module: an operation or a hook.
pub const Entry = struct {
    stage: Stage,
    declaration: type,

    pub const Stage = enum { operation, before, after, event };
};

/// Every operation, then every hook, in declaration order: the numbering the module's
/// `publr_invoke` and the manifest share.
pub fn runtime_entries(comptime Plugin: type) []const Entry {
    comptime {
        const contract = @import("../plugin.zig");
        var entries: []const Entry = &.{};

        for (contract.operations_of(Plugin)) |Operation| {
            entries = entries ++ &[_]Entry{.{ .stage = .operation, .declaration = Operation }};
        }

        for (contract.middleware_of(Plugin)) |Middleware| {
            entries = entries ++ &[_]Entry{.{
                .stage = hook_stage(Plugin, Middleware),
                .declaration = Middleware,
            }};
        }

        if (entries.len > entries_max) {
            @compileError("plugin " ++ Plugin.manifest.name ++ ": too many operations and hooks");
        }

        return entries;
    }
}

fn hook_stage(comptime Plugin: type, comptime Middleware: type) Entry.Stage {
    comptime {
        const name = Plugin.manifest.name;

        if (!@hasDecl(Middleware, "reason")) {
            @compileError("plugin " ++ name ++ ": a hook in the sandbox is asked for like a " ++
                "permission: give it `pub const reason = \"...\"`");
        }

        return switch (Middleware.stage) {
            .before => .before,
            .after => .after,
            .on => on: {
                if (!@hasDecl(Middleware, "event")) {
                    @compileError("plugin " ++ name ++ ": an event hook in the sandbox names " ++
                        "its event: `pub const event = \"record.published\"`");
                }

                break :on .event;
            },
            .pre => @compileError("plugin " ++ name ++ ": pre hooks do not run in the sandbox yet"),
        };
    }
}

/// The input a `before` or `after` hook takes, from its signature.
pub fn HookIn(comptime Middleware: type) type {
    const params = @typeInfo(@TypeOf(Middleware.run)).@"fn".params;

    return @typeInfo(params[1].type.?).pointer.child;
}

/// The output an `after` hook reads, from its signature.
pub fn HookOut(comptime Middleware: type) type {
    const params = @typeInfo(@TypeOf(Middleware.run)).@"fn".params;

    return @typeInfo(params[2].type.?).pointer.child;
}

/// What a plugin may not bring into the sandbox: each needs trust or machinery it lacks.
pub fn assert_sandboxable(comptime Plugin: type) void {
    comptime {
        const name = Plugin.manifest.name;
        const never = [_][]const u8{ "schema_sql", "bootstrap", "sign_in_provider" };
        const later = [_][]const u8{
            "policies", "field_kinds", "delivery_gates", "statuses", "transitions", "filters",
        };

        if (Plugin.manifest.native_only) {
            @compileError("plugin " ++ name ++ ": `native_only` cannot be sandboxed");
        }

        for (never) |declaration| {
            if (@hasDecl(Plugin, declaration)) {
                @compileError("plugin " ++ name ++ ": `" ++ declaration ++ "` needs a " ++
                    "native plugin");
            }
        }

        for (later) |declaration| {
            if (@hasDecl(Plugin, declaration)) {
                @compileError("plugin " ++ name ++ ": `" ++ declaration ++ "` does not run " ++
                    "in the sandbox yet");
            }
        }

        for (permissions_of(Plugin)) |permission| {
            if (permission.reason.len == 0 or permission.reason.len > reason_len_max) {
                @compileError("plugin " ++ name ++ ": permission " ++ permission.key ++
                    " needs a reason of 1 to 200 characters");
            }
        }
    }
}

pub fn permissions_of(comptime Plugin: type) []const Permission {
    comptime {
        if (!@hasDecl(Plugin, "permissions")) {
            return &.{};
        }

        const list: []const Permission = &Plugin.permissions;

        std.debug.assert(list.len <= permissions_max);

        return list;
    }
}

pub fn strings_of(comptime Plugin: type, comptime declaration: []const u8) []const []const u8 {
    comptime {
        if (!@hasDecl(Plugin, declaration)) {
            return &.{};
        }

        const list: []const []const u8 = &@field(Plugin, declaration);

        std.debug.assert(list.len <= domains_max);

        return list;
    }
}

test "entries number operations first, then hooks, and read a hook's shapes from its run" {
    const Plugin = @import("../plugin.zig").testing.Hello;
    const Hook = struct {
        pub const stage: middleware.Stage = .after;
        pub const operation = "hello.record";
        pub const reason = "Counts greetings";

        pub fn run(
            _: *@import("context.zig").PluginCtx,
            _: *Plugin.Record.In,
            _: *const Plugin.Record.Out,
        ) sdk_operation.Error!void {}
    };

    try std.testing.expect(HookIn(Hook) == Plugin.Record.In);
    try std.testing.expect(HookOut(Hook) == Plugin.Record.Out);
    try std.testing.expectEqual(0, comptime permissions_of(Plugin).len);
    try std.testing.expectEqual(0, comptime strings_of(Plugin, "allowed_domains").len);
}

/// Checked where a sandboxed plugin calls `operation_name`, as that call compiles: a call no
/// declared permission covers fails the build, naming the permission to ask for. Its own
/// namespace, the harmless operations and record operations (they may reach its own types,
/// which need nothing; another type is refused when the call runs) pass. The plugin is the
/// module's root's `Plugin`; a build without one (Publr itself, its tests) checks nothing.
pub fn check_call(comptime operation_name: []const u8) void {
    comptime {
        const root = @import("root");

        if (!@hasDecl(root, "Plugin")) {
            return;
        }

        const Plugin = root.Plugin;
        const name = Plugin.manifest.name;
        const label = "plugin " ++ name ++ " calls `" ++ operation_name ++ "`, ";

        std.debug.assert(operation_name.len > 0);

        if (catalog.contains(&catalog.never, operation_name)) {
            @compileError(label ++ "which no plugin may call");
        }

        const own = @import("../plugin_access.zig").own(name, operation_name);
        const free = catalog.contains(&catalog.always, operation_name) or
            catalog.contains(&catalog.own_records, operation_name);

        if (own or free) {
            return;
        }

        var needed: []const u8 = "";

        for (catalog.core) |candidate| {
            if (!catalog.contains(candidate.operations, operation_name)) {
                continue;
            }

            if (asks_for(Plugin, candidate.key)) {
                return;
            }

            needed = candidate.key;
        }

        if (needed.len == 0) {
            @compileError(label ++ "which no permission opens to a plugin");
        }

        @compileError(label ++ "which needs `" ++ needed ++ "`: add " ++
            "`.{ .key = \"" ++ needed ++ "\", .reason = \"<why it needs it>\" }` to its " ++
            "`permissions`");
    }
}

fn asks_for(comptime Plugin: type, comptime key: []const u8) bool {
    comptime {
        std.debug.assert(key.len > 0);

        for (permissions_of(Plugin)) |asked| {
            if (std.mem.eql(u8, asked.key, key)) {
                return true;
            }
        }

        return false;
    }
}
