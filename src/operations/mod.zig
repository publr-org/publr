const std = @import("std");
const sdk = @import("../sdk.zig");
const registry = @import("../server/registry.zig");

const Ctx = sdk.Ctx;
const Grant = sdk.Grant;
const Error = sdk.Error;
const mods = sdk.mods;
const sdk_http = @import("http.zig");
const overrides = @import("operation.zig");
const deps = @import("../lib/deps.zig");
const public = @import("../publr/operations/mod.zig");

pub const namespace = public.namespace;

pub const Apply = struct {
    pub const shape = public.Apply;
    pub const name = shape.name;
    pub const open = shape.open;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (!mods.valid(in.name, false)) {
            return error.Invalid;
        }

        // A plugin's values: held laid out, changed where its caller finds them.
        if (ctx.applying) |held| {
            ctx.applying = null;
            held.* = try registry.SDK.modify_held(ctx, in.name, held.*);

            return .{
                .values = in.values,
            };
        }

        return from_edge(ctx, in);
    }

    /// The outer edge's values, a JSON array: read once, written once, here.
    fn from_edge(ctx: *Ctx, in: In) Error!Out {
        const given = in.values.text;

        std.debug.assert(ctx.applying == null);

        if (given.len > values_bytes_max) {
            return error.Invalid;
        }

        const parsed = std.json.parseFromSliceLeaky([]std.json.Value, ctx.arena, given, .{
            .allocate = .alloc_always,
        }) catch |err| {
            return if (err == error.OutOfMemory) error.OutOfMemory else error.Invalid;
        };

        if (parsed.len > mods.items_max) {
            return error.Invalid;
        }

        if (!registry.SDK.modified(ctx, in.name)) {
            return .{
                .values = in.values,
            };
        }

        var batch: mods.Batch = .{
            .items = parsed,
        };

        try registry.SDK.modify(ctx, in.name, &batch);

        const changed = std.json.Stringify.valueAlloc(ctx.arena, batch.items, .{}) catch {
            return error.OutOfMemory;
        };

        return .{
            .values = .{
                .text = changed,
            },
        };
    }
};

const values_bytes_max: u32 = 1 << 20;

pub const Changed = struct {
    pub const shape = public.Changed;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const open = shape.open;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const field_docs = shape.field_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());

        if (!mods.valid(in.name, false)) {
            return error.Invalid;
        }

        if (ctx.plugin.len == 0 or !try modifies(ctx, ctx.plugin, in.name)) {
            return error.Denied;
        }

        const key = std.fmt.allocPrint(ctx.arena, "mod:{s}", .{in.name}) catch {
            return error.OutOfMemory;
        };

        // What this call read of the site's currencies and media base is read again.
        ctx.site_currencies = null;
        ctx.media_base = null;

        var index: deps.Index = .{
            .db = ctx.db,
            .options = .{
                .quiet_ms = deps.quiet_ms,
            },
        };

        index.invalidate(&.{key}, ctx.now_ms) catch {
            ctx.dependency_failure = true;
        };

        return .{};
    }
};

/// Whether `plugin` has a modifier taking `name`.
fn modifies(ctx: *Ctx, plugin: []const u8, name: []const u8) Error!bool {
    std.debug.assert(plugin.len > 0);
    std.debug.assert(name.len > 0);

    for (try registry.SDK.modifiers(ctx)) |modifier| {
        if (std.mem.eql(u8, modifier.plugin, plugin) and mods.matches(modifier.name, name)) {
            return true;
        }
    }

    return false;
}

pub const List = struct {
    pub const shape = public.List;
    pub const name = shape.name;
    pub const description = shape.description;
    pub const details = shape.details;
    pub const kind = shape.kind;
    pub const In = shape.In;
    pub const Out = shape.Out;
    pub const example = shape.example;
    pub const example_out = shape.example_out;
    pub const output_docs = shape.output_docs;

    pub fn run(ctx: *Ctx, in: In, granted: *const Grant) Error!Out {
        std.debug.assert(granted.allows());
        std.debug.assert(@sizeOf(In) == 0);

        _ = in;

        return .{
            .modifiers = try registry.SDK.modifiers(ctx),
        };
    }
};

pub const operations = [_]type{ Apply, Changed, List };

const SDK = registry.SDK;

test "applied under a name with no modifier, values come back as they went; bad ones refused" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);

    const kept = try SDK.dispatch(&system, Apply, .{
        .name = "nobody.modifies",
        .values = .{
            .text = "[1,{\"a\":2}]",
        },
    });
    try std.testing.expectEqualStrings("[1,{\"a\":2}]", kept.values.text);
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, Apply, .{
        .name = "*.title",
        .values = .{
            .text = "[]",
        },
    }));
    try std.testing.expectError(error.Invalid, SDK.dispatch(&system, Apply, .{
        .name = "x.y",
        .values = .{
            .text = "{}",
        },
    }));
    _ = try SDK.dispatch(&system, List, .{});
}

test "anyone but a plugin modifying a name is refused saying its values changed" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var system = harness.ctx(.system);

    try std.testing.expectError(error.Denied, SDK.dispatch(&system, Changed, .{
        .name = "greeter.salutation.title",
    }));

    system.plugin = "greeter";
    try std.testing.expectError(error.Denied, SDK.dispatch(&system, Changed, .{
        .name = "money.currencies",
    }));
}

test "a visitor's call applies values too: modifiers only read, with their own grants" {
    var harness: sdk.testing.Harness = undefined;
    try harness.init();
    defer harness.deinit();

    var visitor = harness.ctx(.anonymous);

    const kept = try SDK.dispatch(&visitor, Apply, .{
        .name = "checkout.methods",
        .values = .{
            .text = "[[]]",
        },
    });
    try std.testing.expectEqualStrings("[[]]", kept.values.text);
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
        .values = .{
            .text = "[2,40,\"not a number\"]",
        },
    });

    try std.testing.expectEqualStrings("[3,41,\"not a number\"]", changed.values.text);

    const listed = try SDK.dispatch(&ctx, List, .{});
    var found = false;

    for (listed.modifiers) |modifier| {
        found = found or std.mem.eql(u8, modifier.name, "greeter.*");
    }

    try std.testing.expect(found);
}
