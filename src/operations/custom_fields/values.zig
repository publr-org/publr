//! A field group's values on one account: what `publr.fields.get` and `publr.fields.save`
//! call, compiled in or installed. From a plugin's code they reach only its own groups
//! (`<plugin>`, `<plugin>_1`, ...), with no grant asked; wherever the group is placed, so a
//! plugin's location rule may read its own group to decide. A save changes the group's
//! fields only; every other group's values stay. With no plugin running, whoever reads or
//! changes accounts names any group.
const std = @import("std");
const sdk = @import("../../sdk.zig");
const model = @import("../../model.zig");
const json = @import("../../lib/json.zig");
const registry = @import("../../server/registry.zig");
const custom_fields = @import("../custom_fields.zig");
const user_operations = @import("../user.zig");
const user_fields = @import("../user/fields.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const Def = model.field.Def;
const Value = std.json.Value;

const example_values = "{\"motto\":\"Keep notes\"}";

pub const Values = struct {
    pub const name = "custom_fields.values";
    pub const description = "A field group's values on one account";
    pub const details =
        \\From a plugin's code: its own group (`group` left out names `<plugin>`), on the
        \\account wherever the group is placed, with no grant asked. With no plugin running,
        \\whoever reads accounts names any group.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {
        user: []const u8,
        group: ?[]const u8 = null,
    };
    pub const Out = struct {
        values: []const u8,
    };
    pub const example: In = .{
        .user = "admin@example.com",
        .group = "sampler",
    };
    pub const example_out: Out = .{
        .values = example_values,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .user = "The account's id or email",
        .group = "The group's handle; a plugin's own when left out",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .values = "The group's values, a JSON object",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(in.user.len <= 64 << 10);

        var as_core = try AsCore.of(ctx, in.group);
        defer as_core.done();

        const found = try user_operations.find_user(ctx, in.user) orelse return error.NotFound;
        const own = try group_of(ctx, as_core.group);
        const document = try user_fields.read(ctx, found.user.id, &.{own});
        const values = document.object.get(own.name) orelse Value{
            .object = .empty,
        };

        return .{
            .values = try sdk.stringify(ctx.arena, values),
        };
    }
};

pub const SaveValues = struct {
    pub const name = "custom_fields.save_values";
    pub const description = "Change a field group's values on one account";
    pub const details =
        \\The fields `values` names change, checked as every write is; the group's other
        \\fields and every other group stay. From a plugin's code: its own group, with no
        \\grant asked. With no plugin running, whoever changes accounts names any group.
    ;
    pub const kind: sdk.operation.Kind = .write;
    pub const In = struct {
        user: []const u8,
        group: ?[]const u8 = null,
        values: []const u8,
    };
    pub const Out = struct {
        values: []const u8,
    };
    pub const example: In = .{
        .user = "admin@example.com",
        .group = "sampler",
        .values = example_values,
    };
    pub const example_out: Out = .{
        .values = example_values,
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .user = "The account's id or email",
        .group = "The group's handle; a plugin's own when left out",
        .values = "The fields to change, a JSON object",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .values = "The group's values as saved, a JSON object",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(ctx.db.transaction_depth >= 1);

        if (in.values.len > user_fields.document_bytes_max) {
            return error.Invalid;
        }

        var as_core = try AsCore.of(ctx, in.group);
        defer as_core.done();

        const found = try user_operations.find_user(ctx, in.user) orelse return error.NotFound;
        const own = try group_of(ctx, as_core.group);
        const placed = try user_fields.definition(ctx, found.user.id, found.user.roles);
        const defs = if (placed_has(placed, own.name))
            placed
        else
            std.mem.concat(ctx.arena, Def, &.{ placed, &.{own} }) catch {
                return error.OutOfMemory;
            };
        var document = try user_fields.read(ctx, found.user.id, defs);
        const given = json.parse(Value, ctx.arena, in.values, .{}) catch return error.Invalid;

        if (given != .object) {
            return error.Invalid;
        }

        const kept = document.object.getPtr(own.name);
        var group: Value = if (kept) |value| value.* else .{
            .object = .empty,
        };

        if (group != .object) {
            group = .{
                .object = .empty,
            };
        }

        for (given.object.keys(), given.object.values()) |field, value| {
            group.object.put(ctx.arena, field, value) catch return error.OutOfMemory;
        }

        document.object.put(ctx.arena, own.name, group) catch return error.OutOfMemory;

        try user_fields.write(ctx, found.user.id, defs, try sdk.stringify(ctx.arena, document));

        return .{
            .values = try sdk.stringify(ctx.arena, group),
        };
    }
};

/// Reading as core reads: a plugin's own group needs no grant of the plugin's. The group is
/// the plugin's own (`<plugin>` or `<plugin>_<n>`) when a plugin runs, else named.
const AsCore = struct {
    ctx: *Ctx,
    caller: sdk.Caller,
    plugin: []const u8,
    group: []const u8,

    fn of(ctx: *Ctx, named: ?[]const u8) Error!AsCore {
        std.debug.assert(ctx.now_ms >= 0);

        const plugin = ctx.plugin;
        const group = named orelse plugin;

        if (group.len == 0 or group.len > model.content_type.handle_len_max) {
            return error.Invalid;
        }

        if (plugin.len > 0 and !owns(plugin, group)) {
            return error.Denied;
        }

        const kept: AsCore = .{
            .ctx = ctx,
            .caller = ctx.caller,
            .plugin = plugin,
            .group = group,
        };

        ctx.caller = .system;
        ctx.plugin = "";

        return kept;
    }

    fn done(as_core: *const AsCore) void {
        std.debug.assert(as_core.group.len > 0);

        as_core.ctx.caller = as_core.caller;
        as_core.ctx.plugin = as_core.plugin;
    }
};

/// Whether `group` is `plugin`'s own: its name, or its name, `_` and a number.
fn owns(plugin: []const u8, group: []const u8) bool {
    std.debug.assert(plugin.len > 0);

    if (std.mem.eql(u8, plugin, group)) {
        return true;
    }

    const numbered = group.len > plugin.len + 1 and std.mem.startsWith(u8, group, plugin) and
        group[plugin.len] == '_';

    if (!numbered) {
        return false;
    }

    for (group[plugin.len + 1 ..]) |char| {
        if (!std.ascii.isDigit(char)) {
            return false;
        }
    }

    return true;
}

/// The group as the account's fields list it: one group field of its fields.
fn group_of(ctx: *Ctx, handle: []const u8) Error!Def {
    std.debug.assert(handle.len > 0);

    const got = try registry.SDK.dispatch(ctx, custom_fields.Get, .{
        .group = handle,
    });

    return .{
        .name = got.definition.handle,
        .label = got.definition.name,
        .kind = "group",
        .fields = got.definition.fields,
    };
}

fn placed_has(defs: []const Def, handle: []const u8) bool {
    std.debug.assert(handle.len > 0);

    for (defs) |def| {
        if (std.mem.eql(u8, def.name, handle)) {
            return true;
        }
    }

    return false;
}

test "a plugin's own groups only: its name, or its name and a number" {
    try std.testing.expect(owns("loyalty", "loyalty"));
    try std.testing.expect(owns("loyalty", "loyalty_2"));
    try std.testing.expect(!owns("loyalty", "loyalty_x"));
    try std.testing.expect(!owns("loyalty", "loyaltyx"));
    try std.testing.expect(!owns("loyalty", "other"));
}

test "a plugin's own group read and written by field, other groups kept and refused" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);
    try user_operations.seed_admin(&system);
    const admin_id = (try user_operations.find_user(&system, "admin@example.com")).?.user.id;

    for ([_][]const u8{ "loyalty", "other" }) |handle| {
        const text = try std.fmt.allocPrint(
            system.arena,
            "{{\"handle\":\"{s}\",\"name\":\"{s}\",\"kind\":\"component\"," ++
                "\"title_field\":\"\",\"group\":{{\"location\":[{{\"rules\":" ++
                "[{{\"field\":\"destination\",\"value\":\"user\"}}]}}]}}," ++
                "\"fields\":[{{\"name\":\"points\",\"label\":\"Points\"," ++
                "\"kind\":\"integer\"}},{{\"name\":\"tier\",\"label\":\"Tier\"," ++
                "\"kind\":\"string\"}}]}}",
            .{ handle, handle },
        );

        _ = try registry.SDK.dispatch(&system, custom_fields.Create, .{
            .group = handle,
            .definition = text,
        });
    }

    var ctx = harness.ctx(.anonymous);
    ctx.plugin = "loyalty";

    var transaction = try ctx.db.transaction();
    _ = try registry.SDK.dispatch(&ctx, SaveValues, .{
        .user = admin_id,
        .values = "{\"points\":120,\"tier\":\"gold\"}",
    });
    _ = try registry.SDK.dispatch(&ctx, SaveValues, .{
        .user = admin_id,
        .group = "loyalty",
        .values = "{\"points\":130}",
    });
    try transaction.commit();

    const read = try registry.SDK.dispatch(&ctx, Values, .{
        .user = admin_id,
    });
    const Points = struct {
        points: ?i64 = null,
        tier: ?[]const u8 = null,
    };
    const kept = try std.json.parseFromSliceLeaky(Points, ctx.arena, read.values, .{});

    try std.testing.expectEqual(@as(?i64, 130), kept.points);
    try std.testing.expectEqualStrings("gold", kept.tier.?);
    try std.testing.expectEqualStrings("loyalty", ctx.plugin);
    try std.testing.expectError(error.Denied, registry.SDK.dispatch(&ctx, Values, .{
        .user = admin_id,
        .group = "other",
    }));

    ctx.plugin = "elsewhere";
    try std.testing.expectError(error.NotFound, registry.SDK.dispatch(&ctx, Values, .{
        .user = admin_id,
    }));
}
