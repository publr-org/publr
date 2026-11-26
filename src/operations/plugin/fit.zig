//! Whether an installed plugin fits this Publr: built with this release or an earlier one,
//! and calling nothing of core's or a built-in plugin's that this release lacks. Checked as
//! it is installed, and again each time it is loaded.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const sandboxed_plugin = @import("../../model/sandboxed_plugin.zig");
const registry = @import("../../server/registry.zig");

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
    const missing = try model.plugin_fit.missing_calls(
        arena,
        uses,
        &namespace_names,
        &operation_names,
    );

    if (missing.len == 0) {
        return null;
    }

    return .{
        .name = "UsesWhatPublrLacks",
        .message = try std.fmt.allocPrint(
            arena,
            "{s} {s} calls {s}, which Publr {s} does not have. Update the plugin for this Publr.",
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

/// What a plugin may use, as its manifest's `uses` names it: every operation, then every
/// host function.
const offered_all = names: {
    @setEvalBranchQuota(1000 + (operation_names.len + host_names.len) * 64);

    var names: [operation_names.len + host_names.len][]const u8 = undefined;

    for (operation_names, names[0..operation_names.len]) |operation, *name| {
        name.* = "call:" ++ operation;
    }

    for (host_names, names[operation_names.len..]) |host, *name| {
        name.* = "host:" ++ host;
    }

    break :names names;
};

/// An operation on its way out, as a release's migration prompt and roadmap say it.
pub const Deprecation = struct {
    name: []const u8,
    since: []const u8,
    removed_on: []const u8,
    instead: []const u8 = "",
    migration: []const u8,
};

/// Every deprecated operation this Publr runs, core's and the built-in plugins'.
const deprecated_all = listed: {
    const operations = registry.SDK.operations;

    @setEvalBranchQuota(1000 + operations.len * 16);

    var count: usize = 0;

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

    const final = list;

    break :listed final;
};

pub const Surface = struct {
    pub const name = "plugin.surface";
    pub const description = "List what this Publr offers plugins: operations, host functions";
    pub const details =
        \\Anyone signed in. What a plugin built for this Publr may use, by name: the operations
        \\of core and of the built-in plugins, and the functions the sandbox gives a module. A
        \\plugin's manifest lists what it uses (`uses`: `call:<operation>`, `host:<function>`,
        \\`emit:`, `mod:`) and the Publr it was built with (`minimum_publr`); one calling an
        \\operation this list lacks, or built with a later Publr, is refused as it is installed
        \\and as it is loaded. `deprecated` names each operation on its way out, the day it
        \\goes and what to change. Changes nothing.
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
        .offset = "How many to pass over first: the operations, then the host functions",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .publr = "This Publr's release",
        .offered = "What a plugin may use, as its `uses` names it: `call:<operation>`, " ++
            "`host:<function>`",
        .deprecated = "Each operation on its way out, on every page: `since`, `removed_on`, " ++
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
