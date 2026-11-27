//! `publr.modify("variant.title", title)`: a plugin changes a value wherever its owner applies
//! it (`ctx.mod`), shown or saved. `run` takes one value, typed by its parameter, and changes
//! it in place; the batch runs through it in passes, its reads collected and read together
//! between them (`mod_reads.zig`). Pure: no writes, no outside calls. A value that does not
//! read as its type, or for which `run` answers an error of its own, stays as it was; a
//! modifier that runs out of memory, calls or time refuses the whole apply.
const std = @import("std");
const behind_of = @import("../../sdk/plugin/context.zig").behind_of;
const sdk = @import("../../sdk.zig");
const mods = @import("../../sdk/mods.zig");
const mod_reads = @import("../../sdk/plugin/mod_reads.zig");

/// A record's title as core applies it, `<type>.title`: the record's id, its fields typed, and
/// the title a modifier changes.
pub fn Title(comptime Doc: type) type {
    return struct {
        id: []const u8,
        title: []const u8,
        record: Doc,
    };
}

/// A field's help in the editor as core applies it, `<type>.<field>.help`: the field's name,
/// the record as the editor holds it, saved or not, and the help a modifier changes.
pub fn FieldHelp(comptime Doc: type) type {
    return struct {
        field: []const u8,
        help: []const u8,
        record: Doc,
    };
}

/// The value a modifier's `run` takes: its second parameter, by pointer.
pub fn ValueOf(comptime run: anytype) type {
    comptime {
        const params = @typeInfo(@TypeOf(run)).@"fn".param_types;

        if (params.len != 2 or @typeInfo(params[1].?) != .pointer) {
            @compileError("a modifier is `fn (ctx: *publr.Ctx, value: *Value) publr.Error!void`");
        }

        return @typeInfo(params[1].?).pointer.child;
    }
}

/// The value a batch modifier's `run` takes all of: its second parameter, a slice.
pub fn ValuesOf(comptime run: anytype) type {
    comptime {
        const params = @typeInfo(@TypeOf(run)).@"fn".param_types;
        const wrong = "a batch modifier is `fn (ctx: *publr.Ctx, values: []Value) " ++
            "publr.Error!void`";

        if (params.len != 2 or @typeInfo(params[1].?) != .pointer) {
            @compileError(wrong);
        }

        const taken = @typeInfo(params[1].?).pointer;

        if (taken.size != .slice or taken.attrs.@"const") {
            @compileError(wrong);
        }

        return taken.child;
    }
}

/// `run_values` for a batch modifier (`publr.modify_all`): `run` is handed every value at
/// once and changes them where they lie. Its reads are its own, made for the whole batch
/// (`Records.many`, one call to another plugin), never noted one a value. Its error refuses
/// the apply: a batch has no value of its own to leave as it came.
pub fn run_all(
    comptime Value: type,
    comptime run: anytype,
    ctx: anytype,
    items: []Value,
) sdk.Error!void {
    std.debug.assert(items.len <= mods.items_max);
    std.debug.assert(behind_of(ctx).reads == null);

    if (items.len == 0) {
        return;
    }

    return run(ctx, items);
}

pub fn check_name(comptime name: []const u8) void {
    comptime {
        if (!mods.valid(name, true)) {
            @compileError("`" ++ name ++ "` is no mod name: dotted parts of a-z, 0-9 and _, " ++
                "`*` for one whole part");
        }

        if (std.mem.startsWith(u8, name, "computed.")) {
            @compileError("`" ++ name ++ "`: core works computed fields out under " ++
                "`computed.`; modify `" ++ name["computed.".len..] ++ "` to change one");
        }
    }
}

/// What a modifier takes when its values reach it laid out as its own type: the batch.
pub fn Items(comptime Value: type) type {
    return struct {
        items: []Value,
    };
}

/// Runs `run` over values of the modifier's type: each changed where it lies, in
/// passes, the reads they note read together between them. One whose `run` fails stays as
/// it came.
pub fn run_values(
    comptime Value: type,
    comptime run: anytype,
    ctx: anytype,
    items: []Value,
) sdk.Error!void {
    std.debug.assert(items.len <= mods.items_max);
    std.debug.assert(behind_of(ctx).reads == null);

    const memory = ctx.arena();
    var reads: mod_reads.Reads = .{
        .arena = memory,
    };
    const values = memory.alloc(?Value, items.len) catch return error.OutOfMemory;
    const done = memory.alloc(bool, items.len) catch return error.OutOfMemory;

    for (items, values, done) |item, *value, *finished| {
        value.* = item;
        finished.* = false;
    }

    for (0..mod_reads.rounds_max) |_| {
        behind_of(ctx).reads = &reads;

        const passed = pass(Value, run, ctx, values, done);

        behind_of(ctx).reads = null;

        const waiting = try passed;

        if (!waiting) {
            break;
        }

        try reads.settle(ctx);
    }

    for (items, values) |*item, value| {
        item.* = value orelse unreachable;
    }
}

/// One pass of `run` over the values still waiting; whether any waits for a read. A value
/// whose `run` answers an error of its own stays as it came; out of memory, out of calls or
/// a plugin it called stopped is no answer about the value: the whole apply is refused.
fn pass(
    comptime Value: type,
    comptime run: anytype,
    ctx: anytype,
    values: []?Value,
    done: []bool,
) sdk.Error!bool {
    std.debug.assert(values.len == done.len);
    std.debug.assert(values.len <= mods.items_max);

    var waiting = false;

    for (values, done) |*value, *finished| {
        if (finished.*) {
            continue;
        }

        var changed = value.*.?;

        run(ctx, &changed) catch |err| {
            switch (err) {
                error.NotYet => waiting = true,
                error.OutOfMemory, error.Throttled, error.Unavailable => return err,
                else => finished.* = true,
            }

            continue;
        };

        value.* = changed;
        finished.* = true;
    }

    return waiting;
}

test "values already of the modifier's type are changed where they lie; a failed one stays" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const memory = arena_state.allocator();
    const Fake = struct {
        reads: ?*mod_reads.Reads = null,
        memory: std.mem.Allocator,
        lists: u32 = 0,

        pub fn arena(self: *const @This()) std.mem.Allocator {
            return self.memory;
        }

        pub fn call_json(self: *@This(), name: []const u8, _: []const u8) sdk.Error![]const u8 {
            std.debug.assert(name.len > 0);

            self.lists += 1;

            return error.NotFound;
        }
    };
    const Price = struct {
        id: []const u8,
        cents: i64,
        note: ?[]const u8 = null,
    };
    const Modifier = struct {
        fn run(ctx: *Fake, price: *Price) sdk.Error!void {
            std.debug.assert(price.id.len > 0);

            _ = behind_of(ctx).reads.?.answer(u8, "record.query", .{
                .id = price.id,
            }) catch |err| switch (err) {
                error.NotFound => 0,
                else => return err,
            };

            if (price.cents < 0) {
                price.note = "never kept";

                return error.Invalid;
            }

            price.cents *= 2;
            price.note = "doubled";
        }
    };
    var fake: Fake = .{
        .memory = memory,
    };
    var prices = [_]Price{
        .{
            .id = "a",
            .cents = 100,
        },
        .{
            .id = "b",
            .cents = -1,
        },
        .{
            .id = "c",
            .cents = 7,
            .note = "was",
        },
    };
    const Batch = Items(Price);
    const batch: Batch = .{
        .items = &prices,
    };

    try run_values(Price, Modifier.run, &fake, batch.items);

    try std.testing.expectEqual(@as(i64, 200), prices[0].cents);
    try std.testing.expectEqualStrings("doubled", prices[0].note.?);
    try std.testing.expectEqual(@as(i64, -1), prices[1].cents);
    try std.testing.expectEqual(@as(?[]const u8, null), prices[1].note);
    try std.testing.expectEqual(@as(i64, 14), prices[2].cents);
    try std.testing.expectEqual(@as(?*mod_reads.Reads, null), fake.reads);
    try std.testing.expectEqual(@as(u32, 3), fake.lists);

    try run_values(Price, Modifier.run, &fake, prices[0..0]);
}

test "a batch modifier takes every value at once; its error is the whole batch's" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const memory = arena_state.allocator();
    const Fake = struct {
        reads: ?*mod_reads.Reads = null,
        memory: std.mem.Allocator,
        runs: u32 = 0,

        pub fn arena(self: *const @This()) std.mem.Allocator {
            return self.memory;
        }
    };
    const Charge = struct {
        id: []const u8,
        cents: i64,
    };
    const Modifier = struct {
        fn run(ctx: *Fake, charges: []Charge) sdk.Error!void {
            std.debug.assert(charges.len > 0);

            ctx.runs += 1;

            for (charges) |*charge| {
                if (charge.cents < 0) {
                    return error.Invalid;
                }

                charge.cents += @intCast(charges.len);
            }
        }
    };
    var fake: Fake = .{
        .memory = memory,
    };
    var charges = [_]Charge{
        .{
            .id = "a",
            .cents = 100,
        },
        .{
            .id = "b",
            .cents = 7,
        },
    };

    comptime std.debug.assert(ValuesOf(Modifier.run) == Charge);
    try run_all(Charge, Modifier.run, &fake, &charges);

    try std.testing.expectEqual(@as(u32, 1), fake.runs);
    try std.testing.expectEqual(@as(i64, 102), charges[0].cents);
    try std.testing.expectEqual(@as(i64, 9), charges[1].cents);

    // Its error is the whole batch's: nothing is left half changed without a word.
    var refused = [_]Charge{.{
        .id = "c",
        .cents = -1,
    }};

    try std.testing.expectError(error.Invalid, run_all(Charge, Modifier.run, &fake, &refused));
    try run_all(Charge, Modifier.run, &fake, refused[0..0]);
    try std.testing.expectEqual(@as(u32, 2), fake.runs);
}
