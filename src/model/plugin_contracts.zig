//! Whether a plugin's remote contracts fit the plugins it names, as they are now: each
//! operation it uses against the operation its plugin provides, and that plugin's version
//! against the range declared. Pure data: the callers gather what is installed.

const std = @import("std");
const contract = @import("contract.zig");
const depends_on = @import("version_range.zig");

pub const findings_max: u32 = 64;

/// One operation as its plugin provides it.
pub const Provided = struct {
    name: []const u8,
    input: []const contract.Node,
    output: []const contract.Node,
};

/// A plugin there now, compiled in or installed and enabled.
pub const Provider = struct {
    plugin: []const u8,
    version: []const u8,
    operations: []const Provided,
};

/// Another plugin's operation as a plugin uses it.
pub const Used = struct {
    operation: []const u8,
    input: []const contract.Node,
    output: []const contract.Node,
};

/// A plugin as a user of others: what it names and what it uses.
pub const User = struct {
    plugin: []const u8,
    depends_on: []const []const u8,
    compatible_with: []const []const u8,
    remotes: []const Used,
};

pub const Why = enum { out_of_range, no_operation, misfit };

/// A contract that does not fit: the operation, whether the user needs it, and why. A
/// misfit says where (`problem`, in `nodes`).
pub const Finding = struct {
    operation: []const u8,
    required: bool,
    why: Why,
    problem: ?contract.Problem = null,
    nodes: []const contract.Node = &.{},
};

/// The user's contracts that do not fit the providers, into `out`; how many. A plugin that
/// is not there is no finding: a required one is refused by `depends_on`, an optional one
/// simply waits.
pub fn check(user: User, providers: []const Provider, out: []Finding) u32 {
    std.debug.assert(out.len > 0);
    std.debug.assert(user.remotes.len <= findings_max);

    var count: u32 = 0;

    for (user.remotes) |used| {
        if (count == out.len) {
            break;
        }

        if (finding_of(user, used, providers)) |found| {
            out[count] = found;
            count += 1;
        }
    }

    return count;
}

/// Whether a hook the user holds on `operation` may run: it fits, or it was not declared as
/// a remote (nothing to check), or its plugin is not there (it never fires).
pub fn hook_fits(user: User, providers: []const Provider, operation: []const u8) bool {
    std.debug.assert(operation.len > 0);
    std.debug.assert(user.plugin.len > 0);

    for (user.remotes) |used| {
        if (std.mem.eql(u8, used.operation, operation)) {
            return finding_of(user, used, providers) == null;
        }
    }

    return true;
}

fn finding_of(user: User, used: Used, providers: []const Provider) ?Finding {
    std.debug.assert(used.operation.len > 0);
    std.debug.assert(user.plugin.len > 0);

    const target = plugin_of(used.operation);
    const declared = range_of(user.depends_on, target);
    const required = declared != null;
    const range = declared orelse range_of(user.compatible_with, target) orelse "";
    const provider = find(providers, target) orelse return null;
    const base: Finding = .{ .operation = used.operation, .required = required, .why = .misfit };

    if (!depends_on.satisfies(provider.version, range)) {
        var out_of_range = base;

        out_of_range.why = .out_of_range;
        return out_of_range;
    }

    for (provider.operations) |provided| {
        if (std.mem.eql(u8, provided.name, used.operation)) {
            return misfit_of(base, used, provided);
        }
    }

    var missing = base;

    missing.why = .no_operation;
    return missing;
}

fn misfit_of(base: Finding, used: Used, provided: Provided) ?Finding {
    std.debug.assert(base.operation.len > 0);

    if (used.input.len == 0 or provided.input.len == 0) {
        return null;
    }

    var found = base;

    if (contract.check_input(used.input, provided.input)) |problem| {
        found.problem = problem;
        found.nodes = if (problem.on_user_side) used.input else provided.input;
        return found;
    }

    if (used.output.len > 0 and provided.output.len > 0) {
        if (contract.check_output(used.output, provided.output)) |problem| {
            found.problem = problem;
            found.nodes = used.output;
            return found;
        }
    }

    return null;
}

fn find(providers: []const Provider, plugin: []const u8) ?Provider {
    std.debug.assert(plugin.len > 0);

    for (providers) |provider| {
        if (std.mem.eql(u8, provider.plugin, plugin)) {
            return provider;
        }
    }

    return null;
}

/// The range a list gives `plugin` (`""` for any), or null when it does not name it.
fn range_of(list: []const []const u8, plugin: []const u8) ?[]const u8 {
    std.debug.assert(plugin.len > 0);

    for (list) |text| {
        if (text.len == 0) {
            continue;
        }

        const wanted = depends_on.parse(text);

        if (std.mem.eql(u8, wanted.name, plugin)) {
            return wanted.range;
        }
    }

    return null;
}

/// The plugin an operation belongs to: `inventory` for `inventory.adjust` and for
/// `app.inventory.reserve`.
pub fn plugin_of(operation: []const u8) []const u8 {
    std.debug.assert(operation.len > 0);

    const app = std.mem.startsWith(u8, operation, "app.");
    const rest = if (app) operation["app.".len..] else operation;
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;

    return rest[0..dot];
}

/// A finding in words: `app.inventory.reserve: sends quantity, which is of another kind`.
pub fn describe(finding: Finding, buffer: []u8) []const u8 {
    std.debug.assert(buffer.len >= 64);
    std.debug.assert(finding.operation.len > 0);

    var path_buffer: [128]u8 = undefined;
    const path = if (finding.problem) |problem|
        contract.path_of(finding.nodes, problem.node, &path_buffer)
    else
        "";
    const why = switch (finding.why) {
        .out_of_range => "its plugin's version is outside the range declared",
        .no_operation => "its plugin has no such operation",
        .misfit => if (finding.problem) |problem| contract.reason_text(problem.reason) else "",
    };
    const text = if (path.len > 0)
        std.fmt.bufPrint(buffer, "{s}: {s} {s}", .{ finding.operation, path, why })
    else
        std.fmt.bufPrint(buffer, "{s}: {s}", .{ finding.operation, why });

    return text catch buffer[0..0];
}

test "contracts: fit, out of range, misfit, absent" {
    const Accepts = struct { sku: []const u8, quantity: u32 };
    const Answers = struct { held: bool, left: u32 };
    const provider: Provider = .{
        .plugin = "inventory",
        .version = "1.4.0",
        .operations = &.{.{
            .name = "app.inventory.reserve",
            .input = comptime contract.describe(Accepts),
            .output = comptime contract.describe(Answers),
        }},
    };
    const fitting: Used = .{
        .operation = "app.inventory.reserve",
        .input = comptime contract.describe(struct { sku: []const u8, quantity: u32 }),
        .output = comptime contract.describe(struct { held: bool }),
    };
    const misfitting: Used = .{
        .operation = "app.inventory.reserve",
        .input = comptime contract.describe(struct { sku: []const u8 }),
        .output = comptime contract.describe(struct { held: bool }),
    };
    var out: [4]Finding = undefined;

    const fits: User = .{
        .plugin = "cart",
        .depends_on = &.{"inventory@^1.2"},
        .compatible_with = &.{},
        .remotes = &.{fitting},
    };
    try std.testing.expectEqual(@as(u32, 0), check(fits, &.{provider}, &out));

    var too_new = fits;
    too_new.depends_on = &.{"inventory@^2"};
    try std.testing.expectEqual(@as(u32, 1), check(too_new, &.{provider}, &out));
    try std.testing.expectEqual(Why.out_of_range, out[0].why);

    var broken = fits;
    broken.remotes = &.{misfitting};
    try std.testing.expectEqual(@as(u32, 1), check(broken, &.{provider}, &out));
    try std.testing.expect(out[0].required);

    var text_buffer: [256]u8 = undefined;
    const text = describe(out[0], &text_buffer);
    try std.testing.expect(std.mem.indexOf(u8, text, "quantity") != null);

    var optional = broken;
    optional.depends_on = &.{};
    optional.compatible_with = &.{"inventory"};
    try std.testing.expectEqual(@as(u32, 1), check(optional, &.{provider}, &out));
    try std.testing.expect(!out[0].required);
    try std.testing.expect(!hook_fits(optional, &.{provider}, "app.inventory.reserve"));
    try std.testing.expect(hook_fits(optional, &.{}, "app.inventory.reserve"));
    try std.testing.expectEqual(@as(u32, 0), check(optional, &.{}, &out));
}
