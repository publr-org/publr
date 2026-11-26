//! Whether an installed plugin fits this Publr: built with this release or an earlier one,
//! and calling nothing of core's or a built-in plugin's that this release lacks. Checked as
//! it is installed, and again each time it is loaded.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const sandboxed_plugin = @import("../../model/sandboxed_plugin.zig");
const registry = @import("../../server/registry.zig");
const offered = @import("offered.zig");
const template_features = @import("../../template/features.zig");

const Ctx = sdk.Ctx;
const Error = sdk.Error;

const running = @import("../../publr.zig").version;

/// Every operation this Publr runs, core's and the built-in plugins', by name.
const operation_names = names: {
    const operations = registry.SDK.operations;

    @setEvalBranchQuota(1000 + operations.len * 8);

    var names: [operations.len][]const u8 = undefined;

    for (operations, &names) |Operation, *name| {
        name.* = Operation.name;
    }

    break :names names;
};

/// Every namespace those operations belong to.
const namespace_names = names: {
    const namespaces = registry.SDK.namespaces;
    var names: [namespaces.len][]const u8 = undefined;

    for (namespaces, &names) |namespace, *name| {
        name.* = namespace.name;
    }

    break :names names;
};

/// What a manifest says of the Publr it needs.
pub const Needs = struct {
    name: []const u8,
    version: []const u8,
    minimum_publr: []const u8 = "",
    uses: []const []const u8 = &.{},
};

pub const Refusal = struct {
    name: []const u8,
    message: []const u8,
};

/// Why a plugin needing `needs` does not fit this Publr, or null when it does.
pub fn refusal(arena: std.mem.Allocator, needs: Needs) error{OutOfMemory}!?Refusal {
    std.debug.assert(needs.name.len > 0);
    std.debug.assert(running.len > 0);

    if (!model.plugin_fit.new_enough(needs.minimum_publr, running)) {
        return .{
            .name = "NeedsNewerPublr",
            .message = try std.fmt.allocPrint(
                arena,
                "{s} {s} needs Publr {s} or later; this site runs {s}. Update Publr first.",
                .{ needs.name, needs.version, needs.minimum_publr, running },
            ),
        };
    }

    const uses = needs.uses[0..@min(needs.uses.len, model.plugin_fit.uses_max)];
    const missing = try model.plugin_fit.missing(arena, uses, .{
        .namespaces = &namespace_names,
        .operations = &operation_names,
        .item_namespaces = &offered.namespaces,
        .events = &offered.event_names,
        .mods = &mod_names,
        .mod_endings = &offered.mod_endings,
    });

    if (missing.len == 0) {
        return null;
    }

    return .{
        .name = "UsesWhatPublrLacks",
        .message = try std.fmt.allocPrint(
            arena,
            "{s} {s} uses {s}, which Publr {s} does not have. Update the plugin for this Publr.",
            .{ needs.name, needs.version, try std.mem.join(arena, ", ", missing), running },
        ),
    };
}

/// Refuses `manifest` when it does not fit this Publr, saying why.
pub fn check(ctx: *Ctx, manifest: *const sandboxed_plugin.Manifest) Error!void {
    std.debug.assert(manifest.name.len > 0);

    const refused = try refusal(ctx.arena, .{
        .name = manifest.name,
        .version = manifest.version,
        .minimum_publr = manifest.minimum_publr,
        .uses = manifest.uses,
    }) orelse return;

    return ctx.fail(.{
        .name = refused.name,
        .status = 409,
        .message = refused.message,
    });
}

/// The host functions a module may import, by name.
const host_names = names: {
    const imports = @import("../../server/sandboxed_plugins/invoke.zig").imports;
    var names: [imports.len][]const u8 = undefined;

    for (imports, &names) |import, *name| {
        name.* = import.name;
    }

    break :names names;
};

/// The mods core applies, by name.
const mod_names = names: {
    var names: [offered.mods.len][]const u8 = undefined;

    for (offered.mods, &names) |mod, *name| {
        name.* = mod.name;
    }

    break :names names;
};

/// What a plugin may use, as its manifest's `uses` names it: every operation, every host
/// function, every event core has (`event:`, which a plugin's `emit:` and `hook:` name; an
/// operation is an event too, under its own name), every mod core applies by name.
const offered_all = names: {
    const total = operation_names.len + host_names.len + offered.event_names.len +
        mod_names.len + template_features.offered.len;

    @setEvalBranchQuota(1000 + total * 64);

    var names: [total][]const u8 = undefined;
    var index: usize = 0;

    for (operation_names) |operation| {
        names[index] = "call:" ++ operation;
        index += 1;
    }

    for (host_names) |host| {
        names[index] = "host:" ++ host;
        index += 1;
    }

    for (offered.event_names) |event| {
        names[index] = "event:" ++ event;
        index += 1;
    }

    for (mod_names) |mod| {
        names[index] = "mod:" ++ mod;
        index += 1;
    }

    for (template_features.offered) |feature| {
        names[index] = feature;
        index += 1;
    }

    const final = names;

    break :names final;
};

/// An item on its way out (`call`, `event`, `mod`), as a release's migration prompt and
/// roadmap say it.
pub const Deprecation = struct {
    kind: []const u8 = "call",
    name: []const u8,
    since: []const u8,
    removed_on: []const u8,
    instead: []const u8 = "",
    migration: []const u8,
};

/// Every deprecated operation this Publr runs, core's and the built-in plugins', then every
/// deprecated event and mod of core's.
const deprecated_all = listed: {
    const operations = registry.SDK.operations;

    @setEvalBranchQuota(1000 + operations.len * 16);

    var count: usize = offered.deprecated.len + template_features.deprecated.len;

    for (operations) |Operation| {
        if (sdk.operation.deprecation(Operation) != null) {
            count += 1;
        }
    }

    var list: [count]Deprecation = undefined;
    var index: usize = 0;

    for (operations) |Operation| {
        const found = sdk.operation.deprecation(Operation) orelse continue;

        list[index] = .{
            .name = Operation.name,
            .since = found.since,
            .removed_on = found.removed_on,
            .instead = found.instead,
            .migration = found.migration,
        };
        index += 1;
    }

    for (offered.deprecated) |item| {
        list[index] = .{
            .kind = item.kind,
            .name = item.name,
            .since = item.deprecated.since,
            .removed_on = item.deprecated.removed_on,
            .instead = item.deprecated.instead,
            .migration = item.deprecated.migration,
        };
        index += 1;
    }

    for (template_features.deprecated) |item| {
        list[index] = .{
            .kind = "template",
            .name = item.name,
            .since = item.deprecated.since,
            .removed_on = item.deprecated.removed_on,
            .instead = item.deprecated.instead,
            .migration = item.deprecated.migration,
        };
        index += 1;
    }

    const final = list;

    break :listed final;
};

pub const Surface = struct {
    pub const name = "plugin.surface";
    pub const description = "List what this Publr offers plugins: operations, events, mods";
    pub const details =
        \\Anyone signed in. What a plugin built for this Publr may use, by name: the operations
        \\of core and of the built-in plugins (`call:`; each is an event too), the functions
        \\the sandbox gives a module (`host:`), core's events (`event:`, which a plugin emits
        \\or hooks: `emit:`, `hook:` in its `uses`), the mods core applies by name (`mod:`)
        \\and what an app's templates use (`template:`: functions, directives, attributes,
        \\settings).
        \\A plugin's manifest lists what it uses and the Publr it was built with
        \\(`minimum_publr`); one using what this list lacks in a namespace of core's, or built
        \\with a later Publr, is refused as it is installed and as it is loaded. `deprecated`
        \\names each item on its way out, its kind, the day it goes and what to change.
        \\Changes nothing.
    ;

    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        limit: u32 = 200,
        offset: u32 = 0,
    };
    pub const Out = struct {
        publr: []const u8,
        offered: []const []const u8,
        deprecated: []const Deprecation = &.{},
        more: bool = false,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .limit = "How many to list; 200 when omitted, up to 200",
        .offset = "How many to pass over first: operations, host functions, events, mods",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .publr = "This Publr's release",
        .offered = "What a plugin or app may use: `call:<operation>`, `host:<function>`, " ++
            "`event:<event>`, `mod:<mod>`, `template:<feature>`",
        .deprecated = "Each item on its way out, on every page: `kind`, `since`, `removed_on`, " ++
            "`instead`, `migration`",
        .more = "Whether more follow past this page",
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .publr = "0.8.3",
        .offered = &.{ "call:money.text", "host:publr_emit" },
        .more = true,
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const sdk.Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.now_ms >= 0);
        std.debug.assert(offered_all.len > 0);

        if (in.limit == 0 or in.limit > sdk.operation.page_limit_max) {
            return error.Invalid;
        }

        const start = @min(in.offset, offered_all.len);
        const end = @min(offered_all.len, start + in.limit);

        return .{
            .publr = running,
            .offered = offered_all[start..end],
            .deprecated = &deprecated_all,
            .more = end < offered_all.len,
        };
    }
};

test {
    _ = offered;
}

comptime {
    // An event's or a mod's `instead` names an operation, event or mod this Publr has, as an
    // operation's does (registry.zig).
    @setEvalBranchQuota(1000 + offered_all.len * 64);

    for (offered.deprecated) |item| {
        const instead = item.deprecated.instead;

        if (instead.len == 0) {
            continue;
        }

        const named = listed(&operation_names, instead) or
            listed(&offered.event_names, instead) or listed(&mod_names, instead);

        if (!named) {
            @compileError(item.name ++ ": `deprecated.instead` names " ++ instead ++
                ", which Publr lacks");
        }
    }
}

fn listed(comptime names: []const []const u8, comptime name: []const u8) bool {
    comptime {
        std.debug.assert(name.len > 0);

        for (names) |one| {
            if (std.mem.eql(u8, one, name)) {
                return true;
            }
        }

        return false;
    }
}

/// The deprecation of what a plugin's `uses` entry names (`call:money.texts`; `emit:` and
/// `hook:` name an event or an operation, `mod:` a mod), when it is on its way out.
pub fn deprecation_of_use(used: []const u8) ?Deprecation {
    std.debug.assert(used.len > 0);

    const colon = std.mem.indexOfScalar(u8, used, ':') orelse return null;
    const kind = used[0..colon];
    const name = used[colon + 1 ..];
    const as_event = std.mem.eql(u8, kind, "emit") or std.mem.eql(u8, kind, "hook");

    for (deprecated_all) |item| {
        if (!std.mem.eql(u8, item.name, name)) {
            continue;
        }

        const call = std.mem.eql(u8, item.kind, "call");
        const matched = if (std.mem.eql(u8, kind, "call"))
            call
        else if (as_event)
            call or std.mem.eql(u8, item.kind, "event")
        else
            std.mem.eql(u8, kind, item.kind);

        if (matched) {
            return item;
        }
    }

    return null;
}
