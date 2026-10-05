//! What a plugin declares to run in the sandbox, on top of what every plugin declares: the
//! permissions it asks for and why, the domains it fetches from, the limits it needs, the
//! plugins it cannot work without. `manifest.zig` turns all of it into the manifest.
const std = @import("std");
const sdk_operation = @import("../operation.zig");
const middleware = @import("../middleware.zig");

pub const permissions_max: u32 = 64;
pub const domains_max: u32 = 32;
pub const reason_len_max: u32 = 200;
pub const entries_max: u32 = 256;

const sandboxed_plugin = @import("../../model/sandboxed_plugin.zig");
const catalog = @import("../../model/permission.zig");
const context = @import("context.zig");

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

    pub const Stage = enum { operation, before, after, event, display };
};

/// Every operation, then every hook, in declaration order, that runs in the sandbox: the
/// numbering the module's `publr_invoke` and the manifest share. What does not run there is
/// left out (`left_out`), never an error: every plugin builds for the sandbox.
pub fn runtime_entries(comptime Plugin: type) []const Entry {
    comptime {
        const contract = @import("../plugin.zig");
        var entries: []const Entry = &.{};

        for (contract.operations_of(Plugin)) |Operation| {
            if (!context.takes_plugin_ctx(Operation.run)) {
                continue;
            }

            entries = entries ++ &[_]Entry{.{ .stage = .operation, .declaration = Operation }};
        }

        for (contract.middleware_of(Plugin)) |Middleware| {
            if (hook_left_out(Middleware) != null) {
                continue;
            }

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
        std.debug.assert(hook_left_out(Middleware) == null);
        std.debug.assert(Plugin.manifest.name.len > 0);

        return switch (Middleware.stage) {
            .before => .before,
            .after => .after,
            .on => .event,
            .display => .display,
            .pre => unreachable,
        };
    }
}

/// Why a hook does not run in the sandbox, or null when it does.
fn hook_left_out(comptime Middleware: type) ?[]const u8 {
    comptime {
        std.debug.assert(@hasDecl(Middleware, "run"));

        if (!context.takes_plugin_ctx(Middleware.run)) {
            return "it takes the host's context";
        }

        if (!@hasDecl(Middleware, "reason")) {
            return "it has no `reason` (a hook is asked for like a permission)";
        }

        if (Middleware.stage == .pre) {
            return "pre hooks do not run in the sandbox yet";
        }

        if (Middleware.stage == .on and !@hasDecl(Middleware, "event")) {
            return "an event hook names its `event`";
        }

        return null;
    }
}

/// What a plugin brings that does not run in the sandbox, each with why: left out of its
/// sandboxed build, which says so, rather than refused. Calls to what is left out answer
/// `Unavailable`; hooks left out never run.
pub fn left_out(comptime Plugin: type) []const []const u8 {
    comptime {
        const contract = @import("../plugin.zig");
        const never = [_][]const u8{ "schema_sql", "bootstrap", "sign_in_provider" };
        const later = [_][]const u8{
            "policies",
            "field_kinds",
            "delivery_gates",
            "statuses",
            "transitions",
            "filters",
            "routes",
            "settings_pages",
            "top_bar",
            "sign_in_at",
            "app_picker_segment",
            "State",
            "operator_commands",
            "before_command",
            "serving",
        };
        var list: []const []const u8 = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        for (never) |declaration| {
            if (@hasDecl(Plugin, declaration)) {
                list = list ++ &[_][]const u8{"`" ++ declaration ++ "`: needs a native plugin"};
            }
        }

        for (later) |declaration| {
            if (@hasDecl(Plugin, declaration)) {
                list = list ++ &[_][]const u8{"`" ++ declaration ++ "`: not in the sandbox yet"};
            }
        }

        for (contract.operations_of(Plugin)) |Operation| {
            if (!context.takes_plugin_ctx(Operation.run)) {
                list = list ++ &[_][]const u8{"operation " ++ Operation.name ++
                    ": it takes the host's context"};
            }
        }

        for (contract.middleware_of(Plugin)) |Middleware| {
            if (hook_left_out(Middleware)) |why| {
                list = list ++ &[_][]const u8{"hook on " ++ hook_target(Middleware) ++ ": " ++ why};
            }
        }

        return list;
    }
}

fn hook_target(comptime Middleware: type) []const u8 {
    comptime {
        std.debug.assert(@hasDecl(Middleware, "stage"));

        if (Middleware.stage == .display) {
            return @import("../display.zig").target_of(Middleware);
        }

        if (@hasDecl(Middleware, "operation")) {
            return Middleware.operation;
        }

        return if (@hasDecl(Middleware, "event")) Middleware.event else "an event";
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

/// What a plugin must get right to be built for the sandbox at all: a reason for each
/// permission it asks for. What cannot run there is left out instead (`left_out`).
pub fn assert_sandboxable(comptime Plugin: type) void {
    comptime {
        const name = Plugin.manifest.name;

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

        const call_key = "call:" ++ operation_name;

        if (catalog.called_operation(call_key) != null and asks_for(Plugin, call_key)) {
            const depends_on = @import("depends_on.zig");

            const optional = @import("../plugin.zig").compatible_with_of(Plugin);
            const declared = depends_on.of(Plugin) ++ optional;

            for (declared) |text| {
                const target = depends_on.parse(text).name;

                if (@import("../plugin_access.zig").own(target, operation_name)) {
                    return;
                }
            }

            @compileError(label ++
                "but the plugin it belongs to is in neither `depends_on` nor `compatible_with`");
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

test "what the sandbox cannot run is left out and named, never refused" {
    const Plugin = struct {
        pub const manifest = .{ .name = "tables", .version = "0.1.0", .summary = "Own tables" };
        pub const schema_sql = "CREATE TABLE tables_rows (id INTEGER PRIMARY KEY)";
        pub const policies = [_]type{};
    };
    const list = comptime left_out(Plugin);

    try std.testing.expectEqual(@as(usize, 2), list.len);
    try std.testing.expectEqualStrings("`schema_sql`: needs a native plugin", list[0]);
    try std.testing.expectEqualStrings("`policies`: not in the sandbox yet", list[1]);
}
