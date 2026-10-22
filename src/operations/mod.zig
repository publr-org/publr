const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const mods = sdk.mods;
const sdk_http = @import("http.zig");
const overrides = @import("operation.zig");

pub const namespace: sdk.operation.Namespace = .{
    .name = "mod",
    .label = "Modifiers",
    .area = .background,
    .summary = "Values plugins change: applied under a name, modified by whoever hooks it",
    .details =
    \\An owner passes a value through a name wherever it makes it (`ctx.mod("checkout.
    \\methods", methods)` in a plugin, `<type>.title` in core), shown or about to be saved,
    \\and every plugin's `publr.modify("checkout.methods", …)` changes it in turn: compiled
    \\in first, then installed, each in the order its plugin was loaded. A modifier's name
    \\may hold `*` for one part (`*.title`). Nothing is declared ahead: a name nobody
    \\modifies comes back as it went. Modifiers only read: no writes, no outside calls.
    ,
};

pub const Apply = struct {
    pub const name = "mod.apply";
    pub const description = "Pass values through every modifier of a name";
    pub const details =
        \\`values` is a JSON array; each modifier taking `name` changes them in turn, and the
        \\array comes back as the last left it. A value a modifier cannot read, or whose
        \\modifier fails, stays as it was. What `ctx.mod` calls; any plugin may.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = mods.Apply.In;
    pub const Out = mods.Apply.Out;
    pub const example: In = .{
        .name = "checkout.methods",
        .values = "[[{\"name\":\"Courier\"}]]",
    };
    pub const example_out: Out = .{
        .values = "[[{\"name\":\"Courier\"}]]",
    };
    pub const field_docs: sdk.operation.Docs(In) = .{
        .name = "The name the values are applied under: dotted parts of a-z, 0-9 and _",
        .values = "The values, as a JSON array, up to 200",
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .values = "The values as the modifiers left them, a JSON array in the same order",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (!mods.valid(in.name, false) or in.values.len > 1 << 20) {
            return error.Invalid;
        }

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, ctx.arena, in.values, .{
            .allocate = .alloc_always,
        }) catch return error.Invalid;

        if (parsed != .array or parsed.array.items.len > mods.items_max) {
            return error.Invalid;
        }

        if (!registry.SDK.modified(ctx, in.name)) {
            return .{
                .values = in.values,
            };
        }

        var batch: mods.Batch = .{
            .items = parsed.array.items,
        };

        try registry.SDK.modify(ctx, in.name, &batch);

        return .{
            .values = std.json.Stringify.valueAlloc(ctx.arena, batch.items, .{}) catch {
                return error.OutOfMemory;
            },
        };
    }
};

pub const List = struct {
    pub const name = "mod.list";
    pub const description = "List every modifier: whose it is, the name it takes, why";
    pub const details =
        \\Compiled-in plugins' modifiers first, then installed ones, in the order they run.
        \\A name with `*` takes every name matching it part by part.
    ;
    pub const kind: sdk.operation.Kind = .read;
    pub const In = struct {};
    pub const Out = struct {
        modifiers: []const mods.Modifier,
    };
    pub const example: In = .{};
    pub const example_out: Out = .{
        .modifiers = &.{
            .{
                .plugin = "greeter",
                .name = "greeter.salutation.title",
                .reason = "Shows a salutation the way a test needs to see it",
            },
            .{
                .plugin = "greeter",
                .name = "greeter.*",
                .reason = "Adds one to every number greeter's names carry, for the tests",
            },
        },
    };
    pub const output_docs: sdk.operation.Docs(Out) = .{
        .modifiers = "Each modifier: `plugin`, `name` (may hold `*`), `reason`",
    };

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(@sizeOf(In) == 0);

        _ = in;

        return .{
            .modifiers = try registry.SDK.modifiers(ctx),
        };
    }
};

pub const operations = [_]type{ Apply, List };

const SDK = registry.SDK;

test "applied under a name with no modifier, values come back as they went; bad ones refused" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);

    const kept = try SDK.dispatch(&system, Apply, .{
        .name = "nobody.modifies",
        .values = "[1,{\"a\":2}]",
    });
    try std.testing.expectEqualStrings("[1,{\"a\":2}]", kept.values);
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, Apply, .{
        .name = "*.title",
        .values = "[]",
    }));
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, Apply, .{
        .name = "x.y",
        .values = "{}",
    }));
    _ = try SDK.dispatch(&system, List, .{});
}

test "a visitor's call applies values too: modifiers only read, with their own grants" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var visitor = harness.ctx(.anonymous);

    const kept = try SDK.dispatch(&visitor, Apply, .{
        .name = "checkout.methods",
        .values = "[[]]",
    });
    try std.testing.expectEqualStrings("[[]]", kept.values);
    try std.testing.expectError(error.Denied, SDK.dispatch(&visitor, List, .{}));
}

test "a modifier is pure: no write, no outside call" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var reading = harness.ctx(.system);

    reading.reads_only = true;

    try std.testing.expectError(error.Denied, SDK.dispatch(&reading, sdk_http.Fetch, .{
        .url = "https://api.example.com/quote",
    }));
    try std.testing.expectError(error.Denied, SDK.dispatch(&reading, overrides.Limit, .{
        .name = "operation.list",
        .per_minute = 5,
    }));
}

test "an installed modifier on `greeter.*` changes each value applied as `greeter.count`" {
    const internal = @import("internal.zig");
    var project: internal.TestProject = undefined;
    try project.init();
    defer project.deinit();

    var ctx = project.ctx(.system);

    try std.testing.expect(SDK.modified(&ctx, "greeter.count"));
    try std.testing.expect(!SDK.modified(&ctx, "greeter.count.more"));

    const changed = try SDK.dispatch(&ctx, Apply, .{
        .name = "greeter.count",
        .values = "[2,40,\"not a number\"]",
    });

    try std.testing.expectEqualStrings("[3,41,\"not a number\"]", changed.values);

    const listed = try SDK.dispatch(&ctx, List, .{});
    var found = false;

    for (listed.modifiers) |modifier| {
        found = found or std.mem.eql(u8, modifier.name, "greeter.*");
    }

    try std.testing.expect(found);
}
