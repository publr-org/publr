//! What a plugin declares to run in the sandbox, on top of what every plugin declares: the
//! permissions it asks for and why (`http.fetch` with its domains), the limits it needs, the
//! plugins it cannot work without. `manifest.zig` turns all of it into the manifest.
const std = @import("std");
const plugin_define = @import("../../publr/plugin/define.zig");
const field_kind_define = @import("../../publr/plugin/field_kind_define.zig");
const sdk_operation = @import("../operation.zig");
const hooks = @import("../hooks.zig");

pub const permissions_max: u32 = 64;
pub const reason_len_max: u32 = 200;
pub const entries_max: u32 = 256;

const sandboxed_plugin = @import("../../model/sandboxed_plugin.zig");
const catalog = @import("../../model/permission.zig");
const context = @import("context.zig");

/// More than the defaults, asked for with a reason; each raised limit waits for approval.
pub const Limits = sandboxed_plugin.Limits;
/// One thing the host can run in a plugin's module: an operation or a hook.
pub const Entry = struct {
    stage: Stage,
    declaration: type,

    pub const Stage = enum {
        operation,
        before,
        after,
        event,
        modify,
        job,
        rule_values,
        rule_matches,
        kind_validate,
        kind_text,
        kind_editor,
        dimension_options,
    };
};

/// Every operation, then every hook, in declaration order, that runs in the sandbox: the
/// numbering the module's `publr_invoke` and the manifest share. What does not run there is
/// left out (`left_out`), never an error: every plugin builds for the sandbox.
pub fn runtime_entries(comptime Plugin: type) []const Entry {
    comptime {
        const contract = @import("../plugin.zig");
        var entries: []const Entry = &.{};

        for (plugin_define.get(Plugin, "operations")) |Operation| {
            if (!context.takes_plugin_ctx(Operation.run)) {
                continue;
            }

            entries = entries ++ &[_]Entry{.{
                .stage = .operation,
                .declaration = Operation,
            }};
        }

        for (plugin_define.get(Plugin, "middleware")) |Middleware| {
            if (hook_left_out(Middleware) != null) {
                continue;
            }

            entries = entries ++ &[_]Entry{.{
                .stage = hook_stage(Plugin, Middleware),
                .declaration = Middleware,
            }};
        }

        // A webhook's delivery runs as one of its jobs.
        for (contract.jobs_of(Plugin) ++ contract.webhooks_of(Plugin)) |Job| {
            entries = entries ++ &[_]Entry{.{
                .stage = .job,
                .declaration = Job,
            }};
        }

        for (@import("../../publr/plugin/location_rule_define.zig").given_of(Plugin)) |given| {
            const Rule = struct {
                pub const rule = given;
            };

            entries = entries ++ &[_]Entry{
                .{
                    .stage = .rule_values,
                    .declaration = Rule,
                },
                .{
                    .stage = .rule_matches,
                    .declaration = Rule,
                },
            };
        }

        for (field_kind_define.definitions_of(Plugin)) |Definition| {
            entries = entries ++ &[_]Entry{
                .{
                    .stage = .kind_validate,
                    .declaration = Definition,
                },
                .{
                    .stage = .kind_text,
                    .declaration = Definition,
                },
                .{
                    .stage = .kind_editor,
                    .declaration = Definition,
                },
            };
        }

        // Each dimension's `.options` view, drawn for the field panel's frame.
        for (@import("../../publr/plugin/dimensions.zig").of(Plugin)) |declared| {
            const Dimension = struct {
                pub const dimension = declared;
            };

            entries = entries ++ &[_]Entry{.{
                .stage = .dimension_options,
                .declaration = Dimension,
            }};
        }

        if (entries.len > entries_max) {
            @compileError("plugin " ++ Plugin.manifest.name ++ ": too many operations, hooks, " ++
                "jobs, rules, kinds and dimensions");
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
            .modify => .modify,
            .pre => unreachable,
        };
    }
}

/// A sandboxed build fails on a hook without its words (its `run` function's `///`): it would
/// be left out and never run, which no one notices. Words the build could not find (a list
/// it cannot read) fail it the same way, naming the hook.
pub fn every_hook_has_words(comptime Plugin: type) void {
    comptime {
        std.debug.assert(Plugin.manifest.name.len > 0);

        for (plugin_define.get(Plugin, "middleware")) |Middleware| {
            const takes_ours = context.takes_plugin_ctx(Middleware.run);
            const words = @hasDecl(Middleware, "reason") and Middleware.reason.len > 0;
            const target = if (@hasDecl(Middleware, "event"))
                Middleware.event
            else if (@hasDecl(Middleware, "operation"))
                Middleware.operation
            else if (@hasDecl(Middleware, "pattern"))
                Middleware.pattern
            else
                "";

            if (takes_ours and !words and Middleware.stage != .pre) {
                @compileError("plugin " ++ Plugin.manifest.name ++ ": its " ++
                    @tagName(Middleware.stage) ++ " hook on " ++ target ++ " has no words: " ++
                    "write `///` above its run function, and list it in `.hooks` written out, " ++
                    "as a constant, or as another file's constant (`place.hooks`)");
            }
        }
    }
}

/// Why a hook does not run in the sandbox, or null when it does.
fn hook_left_out(comptime Middleware: type) ?[]const u8 {
    comptime {
        std.debug.assert(@hasDecl(Middleware, "run"));

        if (!context.takes_plugin_ctx(Middleware.run)) {
            return "it takes the host's context";
        }

        if (!@hasDecl(Middleware, "reason") or Middleware.reason.len == 0) {
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
        // `.middleware` holds hooks and `.row_actions` travel in the manifest.
        const carried = [_][]const u8{ "middleware", "row_actions" };
        var list: []const []const u8 = &.{};

        std.debug.assert(Plugin.manifest.name.len > 0);

        if (plugin_define.has(Plugin, "extend")) {
            list = list ++ &[_][]const u8{"`extend`: needs a native plugin"};
        }

        for (plugin_define.options_built_in) |option| {
            const left = plugin_define.has(Plugin, option) and
                !plugin_define.listed_in(&carried, option);

            if (left) {
                list = list ++ &[_][]const u8{"`" ++ option ++ "`: built-in only"};
            }
        }

        for (plugin_define.get(Plugin, "operations")) |Operation| {
            if (!context.takes_plugin_ctx(Operation.run)) {
                list = list ++ &[_][]const u8{"operation " ++ Operation.name ++
                    ": it takes the host's context"};
            }
        }

        for (plugin_define.get(Plugin, "middleware")) |Middleware| {
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

        if (Middleware.stage == .modify) {
            return Middleware.pattern;
        }

        if (@hasDecl(Middleware, "operation")) {
            return Middleware.operation;
        }

        return if (@hasDecl(Middleware, "event")) Middleware.event else "an event";
    }
}

/// The input a `before` or `after` hook takes, from its signature.
pub fn HookIn(comptime Middleware: type) type {
    const params = @typeInfo(@TypeOf(Middleware.run)).@"fn".param_types;

    return @typeInfo(params[1].?).pointer.child;
}

/// The output an `after` hook reads, from its signature.
pub fn HookOut(comptime Middleware: type) type {
    const params = @typeInfo(@TypeOf(Middleware.run)).@"fn".param_types;

    return @typeInfo(params[2].?).pointer.child;
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

pub fn permissions_of(comptime Plugin: type) []const sandboxed_plugin.Ask {
    comptime {
        if (!plugin_define.has(Plugin, "permissions")) {
            return &.{};
        }

        const list: []const sandboxed_plugin.Ask = plugin_define.get(Plugin, "permissions");

        std.debug.assert(list.len <= permissions_max);

        return list;
    }
}

test "entries number operations first, then hooks, and read a hook's shapes from its run" {
    const Plugin = @import("../plugin.zig").testing.Hello;
    const Hook = struct {
        pub const stage: hooks.Stage = .after;
        pub const operation = "hello.record";
        pub const reason = "Counts greetings";

        pub fn run(
            _: *@import("context.zig").PluginCtx,
            _: *Plugin.source.Record.In,
            _: *const Plugin.source.Record.Out,
        ) sdk_operation.Error!void {}
    };

    try std.testing.expect(HookIn(Hook) == Plugin.source.Record.In);
    try std.testing.expect(HookOut(Hook) == Plugin.source.Record.Out);
    try std.testing.expectEqual(0, comptime permissions_of(Plugin).len);
}

/// Marks the module as reaching `name`, an item of Publr or of another plugin, as `kind`
/// (`call`, `emit`, `mod`): an export `publr_uses:<kind>:<name>`, there only when the code
/// reaching it is compiled in, so the list is what the plugin really uses (`plugin check`
/// reads it into the manifest's `uses`).
pub fn uses(comptime kind: []const u8, comptime name: []const u8) void {
    comptime std.debug.assert(name.len > 0);
    comptime std.debug.assert(kind.len > 0);

    if (comptime !@hasDecl(@import("root"), "Plugin")) {
        return;
    }

    _ = Uses(kind ++ ":" ++ name).marker;
}

// A function, not a constant: the compiler's own wasm linker exports functions only.
fn Uses(comptime name: []const u8) type {
    return struct {
        fn marker() callconv(.c) void {}

        comptime {
            @export(&marker, .{
                .name = @import("manifest.zig").uses_prefix ++ name,
            });
        }
    };
}

/// Checked where a sandboxed plugin calls `operation_name`, as that call compiles: a call no
/// declared permission covers fails the build, naming the permission to ask for. Its own
/// namespace, the harmless operations and record operations (they may reach its own types,
/// which need nothing; another type is refused when the call runs) pass. The plugin is the
/// module's root's `Plugin`; a build without one (Publr itself, its tests) checks nothing.
pub fn check_call(comptime operation_name: []const u8) void {
    comptime {
        // Each check compares the name with every entry of a catalog list or one of the
        // plugin's declared lists once, a comparison at most a key's length of branches.
        const compared = catalog.never.len + catalog.always.len + catalog.own_records.len +
            catalog.core.len * catalog.operations_max + permissions_max * 2 +
            @import("depends_on.zig").depends_on_max * 2;

        @setEvalBranchQuota(1000 + compared * catalog.key_len_max);

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

            const optional = plugin_define.get(Plugin, "compatible_with");
            const declared = plugin_define.get(Plugin, "depends_on") ++ optional;

            if (depends_on.names_owner(declared, operation_name)) {
                return;
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
    const Plugin = plugin_define.Bind(struct {
        fn extend(_: *@import("host.zig").Host) sdk_operation.Error!void {}

        pub const plugin = plugin_define.define(.{
            .name = "tables",
            .version = "0.1.0",
        }, .{
            .extend = extend,
        });
    }, plugin_define.Words(.{
        .{ "main", "Own tables" },
    }));
    const list = comptime left_out(Plugin);

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("`extend`: needs a native plugin", list[0]);
}
